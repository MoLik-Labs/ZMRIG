// One page shell, so every screen has the same header, the same nav and the same
// footer. The HTML is a plain template string: no JSX, no hydration, no runtime.

'use strict';

const VERSION = '6.39.0';

const ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

function escape(value) {
  return String(value ?? '').replace(/[&<>"']/g, (character) => ESCAPES[character]);
}

// The same mark as the site: one tone, a Z drawn on a 32-unit grid.
function mark() {
  return `<svg viewBox="0 0 32 32" aria-hidden="true"><path d="M4 5h24v5l-13 12h13v5H4v-5l13-12H4z" fill="currentColor"/></svg>`;
}

const NAV = [
  ['/', 'Fleet'],
  ['/rigs', 'Rigs'],
  ['/enrol', 'Enrol'],
  ['/downloads', 'Downloads'],
  ['/docs', 'API'],
];

function nav(active) {
  return NAV.map(([href, label]) => {
    const current = active === href ? ' class="active" aria-current="page"' : '';
    return `<a href="${href}"${current}>${label}</a>`;
  }).join('');
}

function page({ title, active = '', body, flash = null, flashBad = false, web = true, csrf = null }) {
  const banner = flash ? `<div class="flash${flashBad ? ' bad' : ''}" role="status">${escape(flash)}</div>` : '';

  const head = web
    ? `<header class="top">
    <a class="brand" href="/">${mark()} ZMRIG fleet</a>
    <nav>${nav(active)}</nav>
    <span class="spacer"></span>
    <form method="post" action="/logout">${csrf ? `<input type="hidden" name="csrf" value="${escape(csrf)}">` : ''}<button type="submit">Sign out</button></form>
  </header>`
    : `<header class="top"><a class="brand" href="/">${mark()} ZMRIG fleet</a></header>`;

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="robots" content="noindex,nofollow">
<title>${escape(title)} · ZMRIG fleet</title>
<link rel="stylesheet" href="/assets/app.css?v=${VERSION}">
<script src="/assets/app.js?v=${VERSION}" defer></script>
</head>
<body>
${head}
<main>
${banner}
${body}
</main>
<footer>ZMRIG fleet ${VERSION} · <a href="/docs">the wire protocol</a> · everything here is queued, never pushed</footer>
</body>
</html>`;
}

function login({ error = null, publicUrl = '' } = {}) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="robots" content="noindex,nofollow">
<title>Sign in · ZMRIG fleet</title>
<link rel="stylesheet" href="/assets/app.css?v=${VERSION}">
</head>
<body>
<header class="top"><span class="brand">${mark()} ZMRIG fleet</span></header>
<main style="max-width:26rem;margin-top:3rem">
  <h1>Sign in</h1>
  <p class="muted small">This dashboard has one password. It is whatever
  <code>FLEET_WEB_PASSWORD</code> was set to when the service started.
  ${publicUrl ? '' : ''}</p>
  ${error ? `<div class="flash bad" role="alert">${escape(error)}</div>` : ''}
  <form method="post" action="/login" class="panel">
    <label for="password">Password</label>
    <input id="password" name="password" type="password" autocomplete="current-password" required autofocus>
    <div class="actions"><button class="primary" type="submit">Sign in</button></div>
  </form>
  <p class="muted small">The bot keeps working whether or not anyone is signed in here.</p>
</main>
</body>
</html>`;
}

module.exports = { page, login, escape, VERSION, mark };
