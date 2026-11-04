#!/usr/bin/env node
// The web host.
//
// One process, no dependencies, one port. It serves the built documentation
// site, the download page, the release feed as JSON and three permanent links
// to the current image.
//
//   PORT            listen port (Render sets it)
//   HOST            bind address, 0.0.0.0 by default
//   SITE_ROOT       the built site, site/build by default
//   GITHUB_REPO     owner/name for the release feed
//   GITHUB_API      API base, https://api.github.com by default
//   RELEASES_TTL    how long a release list is reused, in ms (10 minutes)
//   PUBLIC_URL      absolute base for the copyable links on /download
//   ZMRIG_VERSION   version printed in the page footer
//
// Nothing here needs a secret. The GitHub API is read anonymously, which is why
// the feed is cached for ten minutes: 60 requests an hour fits inside the
// unauthenticated rate limit with room for a whole fleet of visitors.

'use strict';

const http = require('node:http');
const path = require('node:path');
const fs = require('node:fs');

const { createApp } = require('./src/app');
const { Releases } = require('../lib/releases');

function log(message) {
  process.stdout.write(`${new Date().toISOString()} ${message}\n`);
}

function main() {
  const port = Number(process.env.PORT || 8080);
  const bind = process.env.HOST || '0.0.0.0';
  const root = path.resolve(process.env.SITE_ROOT || path.join(__dirname, '..', 'site', 'build'));
  const repo = process.env.GITHUB_REPO || 'MoLik-Labs/ZMRIG';
  const ttl = Number(process.env.RELEASES_TTL || 600000);
  const api = process.env.GITHUB_API || undefined;
  const host = (process.env.PUBLIC_URL || process.env.RENDER_EXTERNAL_URL || '').replace(/\/$/, '');
  // The footer's version: the environment if it is set, otherwise the version
  // this checkout is, so `npm start` on a fresh clone does not print nothing.
  let version = process.env.ZMRIG_VERSION || '';
  if (!version) {
    try {
      version = require(path.join(__dirname, '..', 'package.json')).version || '';
    } catch {
      version = '';
    }
  }

  if (!fs.existsSync(path.join(root, 'index.html'))) {
    log(`no site at ${root}: run "npm run build" in site/ first (SITE_ROOT overrides)`);
    process.exit(2);
  }

  const releases = new Releases({ repo, ttl, api, agent: 'ZMRIG-site', log: (message) => log(`releases: ${message}`) });
  const app = createApp({ root, releases, host, log, version });

  const server = http.createServer(app.handler);
  // A page and its assets arrive on one connection; holding it open for a
  // minute costs nothing and saves the TLS/HTTP handshake for every asset.
  server.keepAliveTimeout = 65_000;
  server.headersTimeout = 66_000;
  server.requestTimeout = 30_000;

  server.listen(port, bind, () => {
    const mib = (app.table.raw / 1048576).toFixed(1);
    log(`listening on ${bind}:${server.address().port}`);
    log(`site ${root}`);
    log(`files ${app.table.count} routes, ${mib} MB in memory, compressed on demand`);
    // The pages a visitor opens first, compressed now that the socket is open.
    log(`warming ${app.warm()} pages`);
    log(`releases ${repo}, cached ${Math.round(ttl / 1000)} s`);
    // Warm the feed so the first visitor does not pay for the GitHub round trip.
    releases.latest().then((data) => {
      log(`release feed: stable ${data.stable ? data.stable.tag : 'none'}, beta ${data.beta ? data.beta.tag : 'none'}`);
    });
  });

  const stop = (signal) => {
    log(`${signal}: closing`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  };
  process.on('SIGTERM', () => stop('SIGTERM'));
  process.on('SIGINT', () => stop('SIGINT'));
}

if (require.main === module) main();

module.exports = { main };
