#!/usr/bin/env node
// The one process that runs on Render.
//
// Two services used to be needed: the control plane (`fleet/`) to answer the
// bots and the rigs, and the web host (`serve/`) to answer people. A free Render
// workspace gets 750 instance hours per calendar month, shared by every free
// service, and a 31-day month is 744 hours — so exactly one always-on service
// fits. Two services do not fit at any price below the paid plan, and a service
// that keeps getting suspended for going over the limit is worse than no
// service.
//
// So there is one process, on one port, doing three jobs:
//
//   the bots        Telegram and/or Discord long-poll, configured by the same
//                   FLEET_* environment the control plane has always used
//   the rigs        POST /v1/hello — the device protocol, unchanged
//   the people      GET /              the documentation site (committed, no build)
//                   GET /download      the download page with checksums
//                   GET /iso/v3|v2|beta  302 to the newest image on that channel
//                   GET /api/releases.json the same data, for a script
//                   GET /healthz       one health check covering all three
//
// The site is `web/`, the committed build of `site/` that GitHub Pages serves
// from the same commit. Serving it here costs nothing at deploy time: no npm
// install, no Docusaurus build, no build minutes. It is the same bytes, so the
// two hosts cannot drift.
//
// Nothing is stored: the filesystem is ephemeral on Render, so the fleet's
// memory is FLEET_ROSTER in the environment and every check-in is reconciled
// against it. A restart changes nothing.

'use strict';

const http = require('node:http');
const path = require('node:path');
const fs = require('node:fs');

const fleet = require('../fleet/src/index');
const fleetConfig = require('../fleet/src/config');
const fleetHttp = require('../fleet/src/http');
const alerts = require('../fleet/src/alerts');
const { createApp } = require('../serve/src/app');
const { Releases } = require('../lib/releases');

const ROOT = path.resolve(__dirname, '..');

function stamp() {
  return new Date().toISOString().replace('T', ' ').slice(0, 19);
}

function log(message) {
  process.stdout.write(`${stamp()} ${message}\n`);
}

/** Paths the device protocol owns. Everything else is the documentation site. */
function isDevicePath(pathname) {
  return pathname === '/v1/hello' || pathname.startsWith('/v1/');
}

function version() {
  if (process.env.ZMRIG_VERSION) return process.env.ZMRIG_VERSION;
  try {
    return require(path.join(ROOT, 'package.json')).version || '';
  } catch {
    return '';
  }
}

function build(env = process.env, overrides = {}) {
  const app = fleet.build(env);
  const siteRoot = overrides.siteRoot || path.resolve(env.SITE_ROOT || path.join(ROOT, 'web'));
  // Absolute URLs in the pages and the sitemap. Render tells the process its own
  // address, so a deploy that forgets the variable still emits correct links.
  const host = (env.FLEET_PUBLIC_URL || env.PUBLIC_URL || env.RENDER_EXTERNAL_URL || '').replace(/\/$/, '');

  if (!fs.existsSync(path.join(siteRoot, 'index.html'))) {
    // Not fatal: the rigs and the bots are the part that must not stop because a
    // documentation file is missing. /download and /iso keep working, and every
    // page request says what is wrong instead of pretending.
    log(`no documentation site at ${siteRoot}: pages will answer 503 until it is there`);
  }

  // One release cache for both halves: the bot's /release command and the web
  // download page must not disagree about which image is current, and one cache
  // is one GitHub request per ten minutes instead of two.
  const releases = overrides.releases || new Releases({
    repo: env.GITHUB_REPO || 'MoLik-Labs/ZMRIG',
    ttl: Number(env.RELEASES_TTL || 600000),
    api: env.GITHUB_API || undefined,
    agent: 'ZMRIG-host',
    log: (message) => log(`releases: ${message}`),
  });

  app.releases = releases;

  const site = createApp({
    root: siteRoot,
    releases,
    host,
    log,
    version: version(),
  });

  const deviceHandler = fleetHttp.createHandler({
    config: app.config,
    store: app.store,
    log: app.log,
    releases,
    onEvent: app.onEvent,
    onCheckIn: app.onCheckIn,
    roster: app.roster,
    // The dashboard stays available standalone (`cd fleet && node src/index.js`);
    // here the front door is the documentation, and two HTML surfaces on one
    // origin is one surface too many to keep safe.
    dashboard: false,
    fallthrough: site.handler,
  });

  return { app, site, releases, deviceHandler, siteRoot };
}

function createServer(env = process.env, overrides = {}) {
  const built = build(env, overrides);
  const started = Date.now();

  const server = http.createServer((request, response) => {
    const pathname = (request.url || '/').split('?')[0];

    if (isDevicePath(pathname)) {
      // The rigs come first: they are the reason the process exists, and the
      // handler answers 405/401 itself for anything malformed.
      built.deviceHandler(request, response).catch((error) => {
        log(`device: ${error.message}`);
        if (!response.headersSent) {
          response.writeHead(500, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
        }
        response.end(JSON.stringify({ ok: false, error: 'internal error' }));
      });
      return;
    }

    if (pathname === '/healthz') {
      const devices = built.app.store.devices();
      const enrolled = devices.filter((device) => device.owner).length;
      const body = JSON.stringify({
        ok: true,
        // Three jobs, three answers, so a failing half is visible from the
        // health check instead of from a user.
        bots: {
          telegram: Boolean(built.app.platform.telegram),
          discord: Boolean(built.app.platform.discord),
        },
        fleet: { rigs: enrolled, known: devices.length },
        site: { root: built.siteRoot, files: built.site.table.count },
        uptime_s: Math.round((Date.now() - started) / 1000),
        rss_mb: Math.round(process.memoryUsage().rss / 1048576),
      });
      response.writeHead(200, {
        'content-type': 'application/json; charset=utf-8',
        'content-length': Buffer.byteLength(body),
        'cache-control': 'no-store',
      });
      response.end(body);
      return;
    }

    Promise.resolve(built.site.handler(request, response)).catch((error) => {
      log(`site: ${error.message}`);
      if (!response.headersSent) {
        response.writeHead(500, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' });
      }
      response.end('internal error\n');
    });
  });

  server.keepAliveTimeout = 65_000;
  server.headersTimeout = 66_000;
  server.requestTimeout = 30_000;

  return { server, ...built };
}

function start(env = process.env) {
  const config = fleetConfig.load(env);
  const { problems, warnings } = fleetConfig.validate(config);
  for (const warning of warnings) log(`warning: ${warning}`);

  // The control plane refuses to start with no bot token and no dashboard
  // password, because with neither it can do nothing at all. Here it can: the
  // documentation and the device protocol are jobs in their own right, so those
  // two checks are warnings and only a genuinely broken setting is fatal. A
  // deploy that serves pages and receives check-ins while the operator has not
  // connected a bot yet is a first deployment, not a misconfiguration.
  const fatal = problems.filter((problem) => /^PORT /.test(problem));
  for (const problem of problems.filter((item) => !fatal.includes(item))) {
    log(`warning: ${problem} - the site is served regardless`);
  }
  if (fatal.length) {
    for (const problem of fatal) process.stderr.write(`host: ${problem}\n`);
    process.stderr.write('\nhost: refusing to start. See doc/FLEET.md.\n');
    process.exit(1);
  }

  const { server, app, site, siteRoot } = createServer(env);
  const port = Number(env.PORT || config.port || 8080);
  const bind = env.HOST || config.bind || '0.0.0.0';

  server.listen(port, bind, () => {
    log(`listening on ${bind}:${server.address().port}`);
    log(`site     ${siteRoot}: ${site.table.count} routes`);
    site.warm();
    log(`rigs     ${app.store.devices().filter((device) => device.owner).length} enrolled`);
    log(`bots     ${app.platform.telegram ? 'telegram' : ''}${app.platform.telegram && app.platform.discord ? ' + ' : ''}${app.platform.discord ? 'discord' : ''}${!app.platform.telegram && !app.platform.discord ? 'none (no tokens)' : ''}`);
    if (app.roster.source) log(`roster   ${app.roster.rigs.size} rig(s) from ${app.roster.source}`);
  });

  server.on('error', (error) => {
    process.stderr.write(`host: http: ${error.message}\n`);
    process.exit(1);
  });

  if (app.platform.telegram) app.platform.telegram.start(app.handlers).catch((error) => log(`telegram: ${error.message}`));
  if (app.platform.discord) app.platform.discord.start(app.handlers).catch((error) => log(`discord: ${error.message}`));

  // Silence is the one failure nothing reports, so a timer looks for it.
  const sweepConfig = app.config;
  const sweep = setInterval(() => {
    for (const event of alerts.sweep(app.store, sweepConfig, Date.now())) app.onEvent(event, event.record);
  }, Math.max(5000, sweepConfig.interval * 1000));
  if (sweep.unref) sweep.unref();

  const shutdown = (signal) => {
    log(`${signal}: saving and leaving`);
    app.store.flush();
    server.close(() => process.exit(0));
    if (app.platform.telegram) app.platform.telegram.stop();
    if (app.platform.discord) app.platform.discord.stop();
    setTimeout(() => process.exit(0), 300).unref();
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('unhandledRejection', (error) => log(`unhandled: ${error && error.message}`));

  return { server, app };
}

if (require.main === module) start();

module.exports = { createServer, build, isDevicePath, start };
