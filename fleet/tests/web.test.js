'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const { Store } = require('../src/store');
const ids = require('../src/ids');
const { createServer } = require('../src/http');
const { Releases } = require('../src/releases');
const { substitute } = require('../../tests/common/monero');

const PASSWORD = 'correct horse battery staple';
const WALLET = '46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ';

const CONFIG = {
  interval: 60,
  offline_after: 300,
  queue_limit: 10,
  alert_temp: 85,
  alert_cooldown: 1800,
  alert_hashrate_drop: 0.5,
  web_password: PASSWORD,
  web_enabled: true,
  public_url: 'https://fleet.example.test',
  admins: ['tg:1'],
};

function fakeGitHub() {
  const releases = [
    {
      tag_name: 'v6.37.0',
      name: 'ZMRIG OS 6.37.0',
      prerelease: false,
      draft: false,
      published_at: new Date(Date.now() - 3600_000).toISOString(),
      assets: [
        { name: 'zmrig-os-6.37.0-x86-64-v3.iso', size: 165_000_000, download_count: 12, browser_download_url: 'https://example.test/v3.iso' },
        { name: 'zmrig-os-6.37.0-x86-64-v3.iso.sha256', size: 100, download_count: 3, browser_download_url: 'https://example.test/v3.iso.sha256' },
        { name: 'zmrig-os-stable-x86-64-v3.json', size: 400, download_count: 1, browser_download_url: 'https://example.test/v3.json' },
      ],
    },
    {
      tag_name: 'os-beta',
      name: 'ZMRIG OS (rolling beta)',
      prerelease: true,
      draft: false,
      published_at: new Date(Date.now() - 7200_000).toISOString(),
      assets: [
        { name: 'zmrig-os-6.37.0-x86-64-v2.iso', size: 160_000_000, download_count: 4, browser_download_url: 'https://example.test/v2.iso' },
      ],
    },
  ];

  return async (url) => {
    if (String(url).includes('/releases')) return { ok: true, status: 200, json: async () => releases, text: async () => '' };
    return {
      ok: true,
      status: 200,
      json: async () => ({}),
      text: async () => '{"iso_sha256": "' + 'a'.repeat(64) + '"}',
    };
  };
}

async function fleet({ password = PASSWORD, fetchImpl, roster = null, trustProxy = false } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zmrig-web-'));
  const store = new Store(path.join(dir, 'state.json')).load();
  const releases = new Releases({ fetchImpl: fetchImpl || fakeGitHub(), log: () => {} });
  const { server, web } = createServer({
    config: { ...CONFIG, web_password: password, web_enabled: Boolean(password), trust_proxy: trustProxy },
    store,
    log: () => {},
    releases,
    roster,
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;

  const jar = { cookie: '' };
  async function request(pathname, options = {}) {
    const response = await fetch(`${base}${pathname}`, {
      redirect: 'manual',
      ...options,
      headers: {
        'accept-encoding': options.encoding === false ? 'identity' : 'br, gzip',
        ...(jar.cookie ? { cookie: jar.cookie } : {}),
        ...(options.headers || {}),
      },
    });
    const setCookie = response.headers.get('set-cookie');
    if (setCookie) jar.cookie = setCookie.split(';')[0];
    return response;
  }

  async function signIn(password = PASSWORD, options = {}) {
    const response = await request('/login', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded', ...(options.headers || {}) },
      body: new URLSearchParams({ password }).toString(),
    });
    return response;
  }

  return { base, store, jar, request, signIn, web, close: () => new Promise((resolve) => server.close(resolve)) };
}

function tokenFrom(html) {
  const match = /name="csrf" value="([^"]+)"/.exec(html);
  return match ? match[1] : null;
}

test('without a password there is no dashboard at all', async () => {
  const fleetOne = await fleet({ password: '' });
  try {
    assert.equal(fleetOne.web, null);
    const response = await fleetOne.request('/');
    assert.equal(response.status, 200);
    const body = await response.text();
    assert.equal(response.headers.get('content-type'), 'text/html; charset=utf-8');
    assert.match(body, /ZMRIG fleet/);
    // The public page is the old one: it lists rigs but has no forms and no nav.
    assert.equal(body.includes('/login'), false);
  } finally {
    await fleetOne.close();
  }
});

test('the dashboard refuses everything without a session', async () => {
  const app = await fleet();
  try {
    for (const page of ['/', '/rigs', '/enrol', '/downloads', '/docs']) {
      const response = await app.request(page);
      if (page === '/') {
        assert.equal(response.status, 200);
        assert.match(await response.text(), /Sign in/);
      } else {
        assert.equal(response.status, 303);
        assert.equal(response.headers.get('location'), '/login');
      }
    }

    const post = await app.request('/enrol', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: 'id=ZMR-AAAA-BBBB-CCCC&code=AAAA-AAAA&csrf=x',
    });
    assert.equal(post.status, 200);
    assert.match(await post.text(), /Sign in/);
  } finally {
    await app.close();
  }
});

test('a wrong password is refused, a right one gets a hardened cookie', async () => {
  const app = await fleet();
  try {
    const wrong = await app.signIn('nope');
    assert.equal(wrong.status, 401);
    assert.equal(wrong.headers.get('set-cookie'), null);
    assert.match(await wrong.text(), /wrong password/);

    const right = await app.signIn();
    assert.equal(right.status, 303);
    assert.equal(right.headers.get('location'), '/');
    const cookie = right.headers.get('set-cookie');
    assert.match(cookie, /HttpOnly/);
    assert.match(cookie, /SameSite=Lax/);
    assert.match(cookie, /Path=\//);
    // Secure only when the request came over TLS; the sandbox has no TLS, so it
    // must not be set here or the cookie would be dropped in development.
    assert.equal(/Secure/.test(cookie), false);

    const dashboard = await app.request('/');
    assert.equal(dashboard.status, 200);
    assert.match(await dashboard.text(), /Sign in to/i.test('') ? /x/ : /Fleet/);

    // A tampered cookie is not a session.
    const forged = app.jar.cookie.replace(/.$/, (character) => (character === 'a' ? 'b' : 'a'));
    const response = await fetch(`${app.base}/rigs`, { redirect: 'manual', headers: { cookie: forged } });
    assert.equal(response.status, 303);
  } finally {
    await app.close();
  }
});

test('a spoofed X-Forwarded-For does not buy a fresh throttle budget', async () => {
  // The throttle is keyed by the caller's address, and the address used to come
  // from the *first* entry of X-Forwarded-For — a value the caller writes. Ten
  // wrong passwords from one machine with a different header on each request
  // therefore arrived as ten different clients, and the block never happened.
  const app = await fleet({ trustProxy: true });
  try {
    for (let index = 0; index < 10; index += 1) {
      await app.signIn(`wrong-${index}`, { headers: { 'x-forwarded-for': `10.0.0.${index}, 203.0.113.7` } });
    }
    const blocked = await app.signIn(PASSWORD, { headers: { 'x-forwarded-for': '10.0.0.99, 203.0.113.7' } });
    assert.equal(blocked.status, 429, 'the address the proxy appended is the one counted');

    // The header is also not believed when there is no proxy: a client talking
    // to this process directly sets it itself.
    const direct = await fleet({ trustProxy: false });
    try {
      for (let index = 0; index < 10; index += 1) {
        await direct.signIn(`wrong-${index}`, { headers: { 'x-forwarded-for': `198.51.100.${index}` } });
      }
      const refused = await direct.signIn(PASSWORD, { headers: { 'x-forwarded-for': '198.51.100.250' } });
      assert.equal(refused.status, 429, 'without a proxy the socket address is counted');
    } finally {
      await direct.close();
    }
  } finally {
    await app.close();
  }
});

test('wrong passwords from many addresses are slowed down for everybody', async () => {
  // Rotating the address defeats a per-address counter whatever the header
  // says, so there is a second budget that does not depend on who is asking:
  // past ten failures in the window, each attempt pays a delay first. The owner
  // with the right password still gets in — it just takes a second.
  const app = await fleet({ trustProxy: true });
  try {
    // Both ends of the header change, which is what a botnet or a proxy pool
    // looks like: the per-address counter legitimately sees twelve strangers.
    for (let index = 0; index < 12; index += 1) {
      await app.signIn(`wrong-${index}`, { headers: { 'x-forwarded-for': `10.1.0.${index}, 203.0.113.${index}` } });
    }
    const started = Date.now();
    const correct = await app.signIn(PASSWORD, { headers: { 'x-forwarded-for': '10.9.9.9, 203.0.113.7' } });
    const waited = Date.now() - started;
    assert.equal(correct.status, 303, 'the right password is still accepted');
    assert.ok(waited >= 100, `a delayed attempt waited (${waited} ms)`);
  } finally {
    await app.close();
  }
});

test('the Secure flag follows the proxy setting, not a header anyone can send', async () => {
  const proxied = await fleet({ trustProxy: true });
  try {
    const response = await proxied.signIn(PASSWORD, { headers: { 'x-forwarded-proto': 'https' } });
    assert.match(response.headers.get('set-cookie'), /; Secure/, 'a declared proxy is believed');
  } finally {
    await proxied.close();
  }

  const direct = await fleet({ trustProxy: false });
  try {
    const response = await direct.signIn(PASSWORD, { headers: { 'x-forwarded-proto': 'https' } });
    assert.equal(response.status, 303);
    assert.doesNotMatch(response.headers.get('set-cookie'), /; Secure/, 'an undeclared header is ignored');
  } finally {
    await direct.close();
  }
});

test('too many wrong passwords are throttled', async () => {
  const app = await fleet();
  try {
    for (let index = 0; index < 10; index += 1) await app.signIn(`wrong-${index}`);
    const blocked = await app.signIn(PASSWORD);
    assert.equal(blocked.status, 429);
    assert.match(await blocked.text(), /too many attempts/);
  } finally {
    await app.close();
  }
});

test('signing out clears the cookie and the session', async () => {
  const app = await fleet();
  try {
    await app.signIn();
    const out = await app.request('/logout');
    assert.equal(out.status, 303);
    assert.match(out.headers.get('set-cookie'), /Max-Age=0/);
    app.jar.cookie = '';
    const after = await app.request('/rigs');
    assert.equal(after.status, 303);
  } finally {
    await app.close();
  }
});

test('the overview counts rigs, hashrate and heat', async () => {
  const app = await fleet();
  try {
    const key = crypto.randomBytes(32).toString('hex');
    const record = app.store.claim(key);
    record.owner = 'tg:1';
    record.label = 'basement';
    record.status = { state: 'mining', hashrate: 1200, temp: 63, wallet: WALLET, pool: 'pool:3333', coin: 'xmr', mode: 'max', threads: '8' };
    record.last_seen = Date.now() - 20_000;

    const offlineKey = crypto.randomBytes(32).toString('hex');
    const offline = app.store.claim(offlineKey);
    offline.owner = 'tg:1';
    offline.label = 'attic';
    offline.status = { state: 'mining', hashrate: 9999 };
    offline.last_seen = Date.now() - 3_600_000;

    await app.signIn();
    const body = await (await app.request('/')).text();

    assert.match(body, /1\.2 kH\/s/, 'only the rig that is up counts towards the total');
    assert.match(body, /basement/);
    assert.match(body, /attic/);
    assert.match(body, /Needs attention/);
    assert.match(body, /not seen for 1h/);
  } finally {
    await app.close();
  }
});

test('the overview adds hashrate up per wallet, not per machine', async () => {
  const app = await fleet();
  try {
    const mine = (wallet, hashrate, label) => {
      const record = app.store.claim(crypto.randomBytes(32).toString('hex'));
      record.owner = 'tg:1';
      record.label = label;
      record.status = { state: 'mining', hashrate, temp: 60, wallet };
      record.last_seen = Date.now() - 10_000;
    };
    mine(WALLET, 750, 'shed-1');
    mine(WALLET, 750, 'shed-2');
    mine('888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H', 500, 'garage');

    await app.signIn();
    const body = await (await app.request('/')).text();

    assert.match(body, /By wallet/);
    assert.match(body, /75%/, 'two rigs on one address are three quarters of the fleet');
    assert.match(body, /25%/, 'the borrowed machine is the rest');
    assert.match(body, /2 mining, 2 online/, 'the farm counts its rigs together');
  } finally {
    await app.close();
  }
});

test('a rig page shows its state and every control', async () => {
  const app = await fleet();
  try {
    const key = crypto.randomBytes(32).toString('hex');
    const record = app.store.claim(key);
    record.owner = 'tg:1';
    record.label = 'basement';
    record.status = { state: 'mining', hashrate: 1200, temp: 63, wallet: WALLET, pool: 'pool:3333', coin: 'xmr', mode: 'safe', threads: '8', installed: true, slot: 'a' };
    record.last_seen = Date.now();

    await app.signIn();
    const body = await (await app.request(`/rig/${record.id}`)).text();

    assert.match(body, /basement/);
    assert.match(body, /4Your|46SQLW/, 'the short wallet is printed');
    assert.match(body, /pool:3333/);
    assert.match(body, /safe/);
    for (const verb of ['start', 'stop', 'restart', 'update', 'log', 'reboot']) {
      assert.match(body, new RegExp(`value="${verb}"`));
    }
    assert.ok(tokenFrom(body), 'every form carries a csrf token');

    const missing = await app.request('/rig/ZMR-0000-0000-0000');
    assert.equal(missing.status, 404);
  } finally {
    await app.close();
  }
});

test('the rig page has a control for every command the chat has', async () => {
  const app = await fleet();
  try {
    const record = app.store.claim(crypto.randomBytes(32).toString('hex'));
    record.owner = 'tg:1';
    await app.signIn();
    const html = await (await app.request(`/rig/${record.id}`)).text();

    // /log <rig> [n]: the chat takes 5-80 lines, and so does the form.
    assert.match(html, /name="lines" min="5" max="80"/);
    // /rename <rig> name: applied here rather than queued, because the rig never
    // learns the name.
    assert.match(html, new RegExp(`action="/rig/${record.id}/rename"`));
    assert.match(html, /name="label"/);
  } finally {
    await app.close();
  }
});

test('a name is renamed in place, and a bad one is refused', async () => {
  const app = await fleet();
  try {
    const record = app.store.claim(crypto.randomBytes(32).toString('hex'));
    record.owner = 'tg:1';
    const csrf = tokenFrom(await (await app.signIn()).text()) || tokenFrom(await (await app.request('/')).text());

    const post = (label, token = csrf) =>
      app.request(`/rig/${record.id}/rename`, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ label, csrf: token }).toString(),
      });

    const good = await post('attic rig');
    assert.equal(good.status, 303);
    assert.equal(app.store.get(record.id).label, 'attic rig');
    assert.equal(app.store.state.audit.at(-1).action, 'rename');
    // Nothing was queued: the rig has no opinion about its own name.
    assert.equal(app.store.get(record.id).queue.length, 0);

    const bad = await post('<script>x</script>');
    assert.equal(bad.status, 303);
    assert.match(decodeURIComponent(bad.headers.get('location')), /1-40 letters/);
    assert.equal(app.store.get(record.id).label, 'attic rig');

    const forged = await post('hijacked', 'forged');
    assert.equal(forged.status, 403);
    assert.equal(app.store.get(record.id).label, 'attic rig');
  } finally {
    await app.close();
  }
});

test('a log request carries the number of lines that was asked for', async () => {
  const app = await fleet();
  try {
    const record = app.store.claim(crypto.randomBytes(32).toString('hex'));
    record.owner = 'tg:1';
    const csrf = tokenFrom(await (await app.signIn()).text()) || tokenFrom(await (await app.request('/')).text());

    const ask = (lines) =>
      app.request(`/rig/${record.id}/action`, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ action: 'log', lines, csrf }).toString(),
      });

    await ask('12');
    assert.deepEqual(app.store.get(record.id).queue.at(-1).args, { lines: 12 });

    // Out of range is clamped, not refused: it is a display setting, and the bot
    // clamps the same way.
    await ask('500');
    assert.deepEqual(app.store.get(record.id).queue.at(-1).args, { lines: 80 });
    await ask('');
    assert.deepEqual(app.store.get(record.id).queue.at(-1).args, { lines: 40 });
  } finally {
    await app.close();
  }
});

test('a rig the roster pins says so, and a rig it does not mention does not', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zmrig-web-'));
  const store = new Store(path.join(dir, 'state.json')).load();
  const pinned = store.claim(crypto.randomBytes(32).toString('hex'));
  const loose = store.claim(crypto.randomBytes(32).toString('hex'));
  const roster = {
    rigs: new Map([
      [pinned.id, { id: pinned.id, owner: 'tg:1', label: null, desired: { mode: 'safe', maxtemp: 72, wallet: WALLET } }],
    ]),
  };

  const app = await fleet({ roster });
  // The helper made its own store; move these rigs into it so the pages see them.
  for (const record of [pinned, loose]) {
    record.owner = 'tg:1';
    app.store.state.devices[record.id] = { ...record, queue: [], acks: [] };
  }
  try {
    await app.signIn();
    const pinnedPage = await (await app.request(`/rig/${pinned.id}`)).text();
    assert.match(pinnedPage, /Pinned by the roster/);
    for (const field of ['mode', 'maxtemp', 'wallet']) {
      assert.match(pinnedPage, new RegExp(`<code>${field}</code>`));
    }
    assert.match(pinnedPage, /corrected again on the check-in after that/);

    const loosePage = await (await app.request(`/rig/${loose.id}`)).text();
    assert.equal(loosePage.includes('Pinned by the roster'), false);
  } finally {
    await app.close();
  }
});

test('a form post without a csrf token changes nothing', async () => {
  const app = await fleet();
  try {
    const key = crypto.randomBytes(32).toString('hex');
    const record = app.store.claim(key);
    record.owner = 'tg:1';
    record.status = { state: 'mining', wallet: WALLET };

    await app.signIn();
    const response = await app.request(`/rig/${record.id}/action`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: 'action=stop&csrf=forged',
    });

    assert.equal(response.status, 403);
    assert.equal(app.store.get(record.id).queue.length, 0);
  } finally {
    await app.close();
  }
});

test('a control queues the command and redirects with a message', async () => {
  const app = await fleet();
  try {
    const key = crypto.randomBytes(32).toString('hex');
    const record = app.store.claim(key);
    record.owner = 'tg:1';
    record.status = { state: 'mining' };

    await app.signIn();
    const page = await (await app.request(`/rig/${record.id}`)).text();
    const csrf = tokenFrom(page);

    const response = await app.request(`/rig/${record.id}/action`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ action: 'restart', csrf }).toString(),
    });

    assert.equal(response.status, 303);
    assert.match(response.headers.get('location'), /^\/rig\/.+\?ok=/);
    assert.equal(app.store.get(record.id).queue.at(-1).cmd, 'restart');
    assert.equal(app.store.state.audit.at(-1).action, 'restart');
  } finally {
    await app.close();
  }
});

test('a wallet change is validated, queued once, and an empty form changes nothing', async () => {
  const app = await fleet();
  try {
    const key = crypto.randomBytes(32).toString('hex');
    const record = app.store.claim(key);
    record.owner = 'tg:1';
    record.status = { state: 'mining', wallet: WALLET, pool: 'pool:3333', coin: 'xmr', mode: 'max', threads: '8' };

    await app.signIn();
    const csrf = tokenFrom(await (await app.request(`/rig/${record.id}`)).text());
    const post = (fields) =>
      app.request(`/rig/${record.id}/setup`, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ csrf, ...fields }).toString(),
      });

    const bad = await post({ wallet: 'not-a-wallet' });
    assert.match(bad.headers.get('location'), /err=/);
    assert.equal(app.store.get(record.id).queue.length, 0);

    // The shape is perfect and the checksum is not: the dashboard has to say
    // which of the two it is, because "invalid" sends an operator looking for a
    // length problem that is not there.
    const typo = await post({ wallet: substitute(WALLET, 12) });
    assert.match(decodeURIComponent(typo.headers.get('location')), /checksum does not match/);
    assert.equal(app.store.get(record.id).queue.length, 0);

    const nothing = await post({ wallet: WALLET, pool: 'pool:3333', coin: 'xmr', mode: 'max', threads: '8' });
    assert.match(nothing.headers.get('location'), /err=nothing\+changed|err=nothing%20changed/);

    const good = await post({ wallet: WALLET, pool: 'other.example:4444', coin: 'xmr', mode: 'safe', maxtemp: '70' });
    assert.match(good.headers.get('location'), /ok=/);
    const queued = app.store.get(record.id).queue;
    assert.equal(queued.length, 1, 'one setup command, not one per field');
    assert.deepEqual(queued[0].args, { pool: 'other.example:4444', mode: 'safe', maxtemp: 70 });

    const heat = await post({ mode: 'max', maxtemp: '70' });
    assert.match(heat.headers.get('location'), /err=.*heat/i);
  } finally {
    await app.close();
  }
});

test('enrolling from the web uses the rig code and binds it to the operator', async () => {
  const app = await fleet();
  try {
    const key = crypto.randomBytes(32).toString('hex');
    const record = app.store.claim(key);
    record.last_seen = Date.now();

    await app.signIn();
    const csrf = tokenFrom(await (await app.request('/enrol')).text());

    const wrong = await app.request('/enrol', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ id: record.id, code: 'AAAA-AAAA', csrf }).toString(),
    });
    assert.match(wrong.headers.get('location'), /^\/enrol\?err=/);
    assert.equal(app.store.get(record.id).owner, null);

    const right = await app.request('/enrol', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ id: record.id, code: ids.enrolCode(key).toLowerCase(), label: 'basement', csrf }).toString(),
    });
    assert.match(right.headers.get('location'), /^\/rig\/.+\?ok=/);
    assert.equal(app.store.get(record.id).owner, 'tg:1', 'the rig belongs to the operator chat id, not to "web"');
    assert.equal(app.store.get(record.id).label, 'basement');
  } finally {
    await app.close();
  }
});

test('the download page lists what CI published, with a hash', async () => {
  const app = await fleet();
  try {
    await app.signIn();
    const body = await (await app.request('/downloads')).text();

    assert.match(body, /Stable/);
    assert.match(body, /Rolling beta/);
    assert.match(body, /zmrig-os-6\.37\.0-x86-64-v3\.iso/);
    assert.match(body, /https:\/\/example\.test\/v3\.iso/);
    assert.match(body, /v6\.37\.0/);
    assert.match(body, /zmrig\.os\.fleet=https:\/\/fleet\.example\.test/);
    // The sha256 is fetched from the manifest, not invented.
    assert.match(body, /sha256 a{64}/);
  } finally {
    await app.close();
  }
});

test('the download page survives GitHub being unreachable', async () => {
  const app = await fleet({
    fetchImpl: async () => {
      throw new Error('getaddrinfo ENOTFOUND api.github.com');
    },
  });
  try {
    await app.signIn();
    const response = await app.request('/downloads');
    const body = await response.text();
    assert.equal(response.status, 200);
    assert.match(body, /Browse the releases page/);
    assert.equal(body.includes('zmrig-os-6.37.0'), false);
  } finally {
    await app.close();
  }
});

test('answers are compressed, cached and revalidated', async () => {
  const app = await fleet();
  try {
    const key = crypto.randomBytes(32).toString('hex');
    const record = app.store.claim(key);
    record.owner = 'tg:1';
    record.status = { state: 'mining', hashrate: 1200, temp: 63 };
    record.last_seen = Date.now();
    for (let index = 0; index < 20; index += 1) {
      const other = app.store.claim(crypto.randomBytes(32).toString('hex'));
      other.owner = 'tg:1';
      other.label = `rig-${index}`;
      other.last_seen = Date.now();
      other.status = { state: 'mining', hashrate: 900 };
    }

    await app.signIn();
    const plain = await app.request('/', { encoding: false });
    const text = await plain.text();
    const compressed = await app.request('/');

    assert.equal(plain.status, 200);
    assert.equal(plain.headers.get('content-encoding'), null);
    assert.equal(compressed.headers.get('content-encoding'), 'br');
    assert.match(compressed.headers.get('vary'), /accept-encoding/i);
    assert.match(compressed.headers.get('content-security-policy'), /default-src 'none'/);
    assert.equal(compressed.headers.get('x-content-type-options'), 'nosniff');

    const tag = plain.headers.get('etag');
    assert.ok(tag);
    const revalidated = await app.request('/', { headers: { 'if-none-match': tag } });
    assert.equal(revalidated.status, 304);
    assert.equal((await revalidated.text()).length, 0);

    const css = await app.request('/assets/app.css?6.37.0');
    assert.match(css.headers.get('cache-control'), /immutable/);
    assert.match(await css.text(), /--accent/);
    assert.ok(text.length > 2000);
  } finally {
    await app.close();
  }
});

test('labels are escaped: a rig name is data, not markup', async () => {
  const app = await fleet();
  try {
    const key = crypto.randomBytes(32).toString('hex');
    const record = app.store.claim(key);
    record.owner = 'tg:1';
    record.label = '<img src=x onerror=alert(1)>';
    record.last_seen = Date.now();
    record.status = { state: 'mining' };

    await app.signIn();
    const body = await (await app.request(`/rig/${record.id}`)).text();
    assert.equal(body.includes('<img src=x'), false);
    assert.match(body, /&lt;img src=x/);
  } finally {
    await app.close();
  }
});

test('rendering is fast enough to be worth the word', async () => {
  const app = await fleet();
  try {
    const record = app.store.claim(crypto.randomBytes(32).toString('hex'));
    record.owner = 'tg:1';
    record.label = 'basement';
    record.last_seen = Date.now();
    record.status = { state: 'mining', hashrate: 1200, temp: 63, wallet: WALLET };
    for (let index = 0; index < 50; index += 1) {
      const other = app.store.claim(crypto.randomBytes(32).toString('hex'));
      other.owner = 'tg:1';
      other.label = `rig-${index}`;
      other.last_seen = Date.now();
      other.status = { state: 'mining', hashrate: 500 };
    }

    await app.signIn();
    const samples = [];
    for (let index = 0; index < 30; index += 1) {
      const started = process.hrtime.bigint();
      await (await app.request('/')).text();
      samples.push(Number(process.hrtime.bigint() - started) / 1e6);
    }
    samples.sort((a, b) => a - b);
    const median = samples[Math.floor(samples.length / 2)];
    const p95 = samples[Math.floor(samples.length * 0.95)];

    // Deliberately generous: this includes a TCP connect and the full response
    // on a shared CI runner. What it catches is a page that starts doing real
    // work per request (a disk read, a network call), not a microsecond.
    assert.ok(median < 50, `median ${median.toFixed(1)} ms`);
    assert.ok(p95 < 120, `p95 ${p95.toFixed(1)} ms`);
  } finally {
    await app.close();
  }
});

test('the dashboard marks a rig that cannot be paid, before the chat is read', async () => {
  const app = await fleet();
  try {
    const key = crypto.randomBytes(32).toString('hex');
    const record = app.store.claim(key);
    record.owner = 'tg:1';
    record.label = 'shed';
    record.status = { state: 'mining', hashrate: 1200, temp: 63, wallet: substitute(WALLET, 20), coin: 'xmr' };
    record.last_seen = Date.now();

    await app.signIn();
    const rigPage = await (await app.request(`/rig/${record.id}`)).text();
    assert.match(rigPage, /wallet ✗/, 'the rig page marks the address');
    assert.match(rigPage, /fails its checksum/, 'and says why, in words');
    assert.match(rigPage, /will not start/, 'and what the rig does about it');

    const list = await (await app.request('/rigs')).text();
    assert.match(list, /wallet ✗/);

    // A rig with a good address carries no mark: the tag has to mean something.
    // The store, not the object `claim` returned, and then `touch()`: pages are
    // cached against `store.revision`, so a change nobody told the store about
    // is a change the next request legitimately does not see.
    app.store.get(record.id).status.wallet = WALLET;
    app.store.touch();
    const clean = await (await app.request(`/rig/${record.id}`)).text();
    assert.doesNotMatch(clean, /wallet ✗/);
    assert.doesNotMatch(clean, /fails its checksum/);

    // A plain login is not a wallet and is not a problem: test rigs use names.
    app.store.get(record.id).status.wallet = 'rig-1';
    app.store.touch();
    assert.doesNotMatch(await (await app.request(`/rig/${record.id}`)).text(), /wallet ✗/);
  } finally {
    await app.close();
  }
});

test('the wallet mark costs one decode per address, not one per rig', async () => {
  const app = await fleet();
  try {
    // 120 rigs, one wallet: the shape of every real farm, and the shape the
    // first version of this mark got wrong - it decoded the same address 120
    // times per render, which turned a 1 ms page into a 70 ms page.
    const rigs = [];
    for (let index = 0; index < 120; index += 1) {
      const record = app.store.claim(crypto.randomBytes(32).toString('hex'));
      record.owner = 'tg:1';
      record.label = `rig-${index}`;
      record.last_seen = Date.now();
      record.status = { state: 'mining', hashrate: 900, temp: 60, wallet: WALLET, coin: 'xmr' };
      rigs.push(record);
    }

    await app.signIn();
    await (await app.request('/rigs')).text();

    // With the verdict cached by address, a second render is string work only.
    const started = process.hrtime.bigint();
    const body = await (await app.request('/rigs')).text();
    const elapsed = Number(process.hrtime.bigint() - started) / 1e6;

    assert.match(body, /rig-119/);
    // 120 decodes would be ~24 ms of BigInt Keccak on top of the render; the
    // budget below is loose enough for a shared CI runner and tight enough to
    // fail if the cache stops working.
    assert.ok(elapsed < 25, `rigs page took ${elapsed.toFixed(1)} ms for 120 rigs`);
  } finally {
    await app.close();
  }
});
