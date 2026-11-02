// Environment-first configuration: a bot token in an environment variable is a
// token that is not in a file in a repository. Every value has a default that
// works for a single-operator fleet on a free host.

'use strict';

function text(env, name, fallback = '') {
  const value = env[name];
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : fallback;
}

function number(env, name, fallback) {
  const value = Number.parseInt(text(env, name, ''), 10);
  return Number.isFinite(value) ? value : fallback;
}

function list(env, name) {
  return text(env, name, '')
    .split(/[\s,]+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

/** `tg:123,456` and `dc:789` become `["tg:123","tg:456","dc:789"]`. */
function admins(env) {
  const result = [];
  for (const raw of list(env, 'FLEET_ADMIN_IDS')) {
    if (raw.includes(':')) {
      result.push(raw.toLowerCase());
      continue;
    }
    // A bare number is a Telegram id: that is what a person gets from @userinfobot
    // and it is by far the common case.
    result.push(`tg:${raw.replace(/^tg/, '')}`);
  }
  for (const id of list(env, 'DISCORD_ADMIN_IDS')) {
    result.push(`dc:${id.replace(/^dc:/, '')}`);
  }
  return result;
}

function load(env = process.env) {
  const port = number(env, 'PORT', number(env, 'FLEET_PORT', 8080));
  const config = {
    port,
    // Render and Fly pass PORT; binding to loopback would make the preview and
    // the health check fail, so the default is all interfaces.
    bind: text(env, 'FLEET_BIND', '0.0.0.0'),
    state: text(env, 'FLEET_STATE', './data/fleet.json'),
    public_url: text(env, 'FLEET_PUBLIC_URL', ''),

    telegram_token: text(env, 'TELEGRAM_BOT_TOKEN', ''),
    discord_token: text(env, 'DISCORD_BOT_TOKEN', ''),

    admins: admins(env),
    // Where unsolicited alerts go. Empty means "every admin".
    notify: list(env, 'FLEET_NOTIFY').map((id) => (id.includes(':') ? id : `tg:${id}`)),

    // How often a rig checks in, and when silence becomes "offline". Three
    // missed check-ins is the rule: one is a wifi hiccup, three is a machine.
    interval: number(env, 'FLEET_INTERVAL', 60),
    offline_after: number(env, 'FLEET_OFFLINE_AFTER', 300),

    alert_temp: number(env, 'FLEET_ALERT_TEMP', 85),
    alert_cooldown: number(env, 'FLEET_ALERT_COOLDOWN', 1800),
    alert_hashrate_drop: number(env, 'FLEET_ALERT_HASHRATE_DROP', 0.5),
    log_lines: number(env, 'FLEET_LOG_LINES', 40),

    // A person typing `/` commands cannot produce more than a few a second, so
    // this is a stop for a stuck loop, not a police checkpoint.
    rate_limit: number(env, 'FLEET_RATE_LIMIT', 30),
    rate_window: number(env, 'FLEET_RATE_WINDOW', 60),
    queue_limit: number(env, 'FLEET_QUEUE_LIMIT', 10),
    quiet: text(env, 'FLEET_QUIET', '') === '1',
  };

  if (config.offline_after < config.interval * 2) {
    config.offline_after = config.interval * 3;
  }
  return config;
}

/** What the server refuses to start without, and what it merely warns about. */
function validate(config) {
  const problems = [];
  const warnings = [];

  if (!config.telegram_token && !config.discord_token) {
    problems.push('no bot token: set TELEGRAM_BOT_TOKEN and/or DISCORD_BOT_TOKEN');
  }
  if (config.admins.length === 0) {
    problems.push('no admins: set FLEET_ADMIN_IDS (Telegram ids) and/or DISCORD_ADMIN_IDS');
  }
  if (config.telegram_token && !/^\d+:[A-Za-z0-9_-]{30,}$/.test(config.telegram_token)) {
    warnings.push('TELEGRAM_BOT_TOKEN does not look like a bot token (123456:ABC-DEF...)');
  }
  if (config.port < 1 || config.port > 65535) {
    problems.push(`PORT out of range: ${config.port}`);
  }
  return { problems, warnings };
}

module.exports = { load, validate };
