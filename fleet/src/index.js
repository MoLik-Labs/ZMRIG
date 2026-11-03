// Wiring: one process, one state file, one HTTP port, and as many chat
// platforms as there are tokens in the environment.

'use strict';

const path = require('node:path');
const configLoader = require('./config');
const { Store } = require('./store');
const gate = require('./gate');
const commands = require('./commands');
const alerts = require('./alerts');
const httpApi = require('./http');
const { Releases } = require('./releases');
const { Telegram } = require('./telegram');
const { Discord } = require('./discord');
const format = require('./format');

function stamp() {
  return new Date().toISOString().replace('T', ' ').slice(0, 19);
}

function makeLog(quiet) {
  return (message) => {
    if (quiet) return;
    process.stdout.write(`${stamp()} ${message}\n`);
  };
}

function build(env = process.env) {
  const config = configLoader.load(env);
  const store = new Store(config.state).load();
  const log = makeLog(config.quiet);
  // GitHub releases, cached: the download page asks for them on every visit and
  // the answer changes a few times a week.
  const releases = new Releases({ log });

  const platform = {
    telegram: config.telegram_token ? new Telegram({ token: config.telegram_token, log }) : null,
    discord: config.discord_token ? new Discord({ token: config.discord_token, log }) : null,
  };

  const limiter = new gate.RateLimiter(config.rate_limit, config.rate_window);

  /** Alerts go to every admin on every configured platform. A rig going offline
   *  is worth one DM per operator, and nothing more clever than that. */
  async function broadcast(text, rows) {
    const targets = config.notify.length ? config.notify : config.admins;
    await Promise.all(
      targets.map(async (key) => {
        const [kind, id] = key.split(':');
        try {
          if (kind === 'tg' && platform.telegram) await platform.telegram.send(id, text, rows);
          if (kind === 'dc' && platform.discord) await platform.discord.dm(id, text, rows);
        } catch (error) {
          log(`notify ${key}: ${error.message}`);
        }
      }),
    );
  }

  function onEvent(event, record) {
    log(`event ${event.kind}: ${event.text.replace(/\*\*/g, '')}`);
    broadcast(event.text, [[{ text: 'Open the rig', data: `a:card:${record.id}` }]]).catch(() => {});
  }

  function actorWithRole(actor) {
    const allowed = config.admins.includes(String(actor.key).toLowerCase());
    return { ...actor, key: String(actor.key).toLowerCase(), role: allowed ? 'admin' : 'guest' };
  }

  function reply(run, payload, context) {
    const actor = actorWithRole(payload.actor);

    if (actor.role !== 'admin') {
      // The id is printed so the operator can add it without guessing, and no
      // command is executed for anybody who is not on the list.
      log(`refused ${actor.key} (${actor.name})`);
      return {
        text: [
          '🔒 this bot is private.',
          '',
          `your id is \`${actor.key}\``,
          'an operator can add it to FLEET_ADMIN_IDS, or DISCORD_ADMIN_IDS for Discord.',
        ].join('\n'),
      };
    }

    if (!limiter.allow(actor.key)) return { text: '⏳ too many commands; wait a moment.' };

    return run({ ...payload, actor }, { ...context, actor });
  }

  const handlers = {
    onMessage: (payload) => reply(commands.route, payload, { store, config }),
    onCallback: (payload) => reply(commands.press, payload, { store, config }),
  };

  return { config, store, log, platform, handlers, broadcast, onEvent, limiter, releases };
}

function start(env = process.env) {
  const config = configLoader.load(env);
  const { problems, warnings } = configLoader.validate(config);
  const log = makeLog(config.quiet);

  for (const warning of warnings) log(`warning: ${warning}`);
  if (problems.length) {
    for (const problem of problems) process.stderr.write(`fleet: ${problem}\n`);
    process.stderr.write('\nfleet: refusing to start. See fleet/README.md.\n');
    process.exit(1);
  }

  const app = build(env);
  const { server, web } = httpApi.createServer({
    config: app.config,
    store: app.store,
    log: app.log,
    releases: app.releases,
    onEvent: app.onEvent,
  });

  server.listen(config.port, config.bind, () => {
    app.log(`http     ${config.bind}:${config.port}`);
    app.log(`state    ${path.resolve(config.state)}`);
    app.log(`rigs     ${app.store.devices().filter((device) => device.owner).length} enrolled`);
    app.log(`admins   ${config.admins.join(' ') || 'none'}`);
    app.log(`interval ${config.interval}s, offline after ${config.offline_after}s`);
    app.log(`web      ${web ? 'enabled at /' : 'off (no FLEET_WEB_PASSWORD)'}`);
  });

  server.on('error', (error) => {
    process.stderr.write(`fleet: http: ${error.message}\n`);
    process.exit(1);
  });

  if (app.platform.telegram) {
    app.platform.telegram.start(app.handlers).catch((error) => app.log(`telegram: ${error.message}`));
  }
  if (app.platform.discord) {
    app.platform.discord.start(app.handlers).catch((error) => app.log(`discord: ${error.message}`));
  }

  // Silence is the one failure nothing reports, so a timer looks for it.
  const sweep = setInterval(() => {
    for (const event of alerts.sweep(app.store, app.config, Date.now())) app.onEvent(event, event.record);
  }, Math.max(5000, app.config.interval * 1000));
  if (sweep.unref) sweep.unref();

  const shutdown = (signal) => {
    app.log(`${signal}: saving and leaving`);
    app.store.flush();
    server.close();
    if (app.platform.telegram) app.platform.telegram.stop();
    if (app.platform.discord) app.platform.discord.stop();
    setTimeout(() => process.exit(0), 300).unref();
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('unhandledRejection', (error) => log(`unhandled: ${error && error.message}`));

  return app;
}

/** `node src/index.js --check` prints what the environment says without opening
 *  a socket, which is what a deploy log wants. */
function check(env = process.env) {
  const config = configLoader.load(env);
  const { problems, warnings } = configLoader.validate(config);
  const store = new Store(config.state).load();
  const devices = store.devices();

  process.stdout.write('ZMRIG fleet\n\n');
  process.stdout.write(`telegram   ${config.telegram_token ? 'configured' : 'off'}\n`);
  process.stdout.write(`discord    ${config.discord_token ? 'configured' : 'off'}\n`);
  process.stdout.write(`admins     ${config.admins.join(' ') || 'none'}\n`);
  process.stdout.write(`port       ${config.port}\n`);
  process.stdout.write(`state      ${path.resolve(config.state)}\n`);
  process.stdout.write(`rigs       ${devices.filter((device) => device.owner).length} enrolled, ${devices.length} known\n`);
  process.stdout.write(`interval   ${config.interval}s\n`);
  process.stdout.write(`web        ${config.web_password ? 'enabled' : 'off (FLEET_WEB_PASSWORD unset)'}\n`);
  process.stdout.write(`total      ${format.hashrate(devices.reduce((sum, device) => sum + (Number(device.status && device.status.hashrate) || 0), 0))}\n`);

  for (const warning of warnings) process.stdout.write(`warning    ${warning}\n`);
  for (const problem of problems) process.stdout.write(`problem    ${problem}\n`);
  return problems.length === 0;
}

module.exports = { build, start, check };

if (require.main === module) {
  if (process.argv.includes('--check')) {
    process.exit(check() ? 0 : 1);
  }
  start();
}
