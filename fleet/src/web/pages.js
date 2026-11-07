// The screens. Each one is a pure function of the store, the config and the
// clock, so a test can render any of them without a socket.

'use strict';

const format = require('../format');
const { presence } = require('../store');
const { page, escape, VERSION } = require('./layout');
const { COINS } = require('../commands');
const farms = require('../farms');
const address = require('../address');

// `commands.js` exports the two tables the bot accepts; the dashboard must offer
// exactly the same words or a form would queue something the rig refuses.
const MODES = ['max', 'balanced', 'eco', 'light', 'safe'];

function stateOf(record, config, now) {
  const online = presence(record, config, now);
  if (online !== 'online') return online;
  return record.status.state || 'online';
}

function dot(state) {
  const kind = state === 'mining' ? 'mining' : state === 'offline' ? 'offline' : state === 'stopped' ? 'warn' : 'online';
  return `<span class="dot ${kind}"></span>`;
}

/**
 * What the wallet on this rig is worth, in one word: `ok` when the address
 * decodes on mainnet, `bad` when it does not, '' when the rig has not reported
 * one (a test rig with a plain login is not a problem, it is just not a wallet).
 *
 * The chat says this once, as an alert. A dashboard that says nothing until
 * somebody reads the chat is a dashboard that hides the one thing that costs
 * money, so every list that shows a rig shows this too.
 */
function walletTag(record) {
  const wallet = String((record.status && record.status.wallet) || '');
  const coin = String((record.status && record.status.coin) || 'xmr').toLowerCase();
  // Only something shaped like an address is judged: a test rig logs in with
  // `rig-1`, and calling that a bad wallet would put a red mark on every rig
  // whose login is a name rather than an address.
  if (!wallet || (wallet.length !== 95 && wallet.length !== 106)) return null;
  if (coin !== 'xmr' && coin !== 'monero') return null;
  const verdict = address.check(wallet);
  if (verdict.ok && verdict.net === 'mainnet') return null;

  return verdict.ok
    ? `<span class="tag bad" title="${escape(verdict.net)} address: a mainnet pool cannot pay it">${escape(verdict.net)}</span>`
    : `<span class="tag bad" title="${escape(verdict.reason)}">wallet ✗</span>`;
}

function csrfField(csrf) {
  return `<input type="hidden" name="csrf" value="${escape(csrf)}">`;
}

function totals(store, config, now) {
  const devices = store.devices();
  let rate = 0;
  let hot = 0;
  let mining = 0;
  let online = 0;

  for (const record of devices) {
    const state = stateOf(record, config, now);
    if (state !== 'offline' && state !== 'waiting') online += 1;
    if (state === 'mining') mining += 1;
    if (presence(record, config, now) === 'online') {
      rate += Number(record.status.hashrate) || 0;
      hot = Math.max(hot, Number(record.status.temp) || 0);
    }
  }

  return { devices, rate, hot, mining, online };
}

function rigTable(devices, config, now) {
  if (!devices.length) {
    return `<p class="empty">No rigs yet. <a href="/enrol">Enrol the first one</a> with the Device ID it prints on its console.</p>`;
  }
  return `<table>
    <thead><tr><th>rig</th><th>state</th><th class="num">hashrate</th><th class="num">temp</th><th>last seen</th><th class="num">queued</th></tr></thead>
    <tbody>${devices
      .map((record) => {
        const state = stateOf(record, config, now);
        return `<tr>
          <td>${dot(state)}<a href="/rig/${encodeURIComponent(record.id)}">${escape(record.label || record.id)}</a>${
            walletTag(record) ? ` ${walletTag(record)}` : ''
          }
            <div class="muted small">${escape(record.id)}</div></td>
          <td>${escape(state)}</td>
          <td class="num">${escape(format.hashrate(record.status.hashrate))}</td>
          <td class="num">${record.status.temp ? escape(format.temperature(record.status.temp)) : '-'}</td>
          <td class="muted">${escape(format.ago(record.last_seen, now))}</td>
          <td class="num">${record.queue.length || ''}</td>
        </tr>`;
      })
      .join('')}</tbody>
  </table>`;
}

// ------------------------------------------------------------------ dashboard

function dashboard({ store, config, now, csrf }) {
  const { devices, rate, hot, mining, online } = totals(store, config, now);
  const attention = devices.filter((record) => {
    const state = stateOf(record, config, now);
    return (
      state === 'offline' ||
      state === 'error' ||
      Number(record.status.temp) >= config.alert_temp ||
      record.queue.length > 0 ||
      walletTag(record) !== null
    );
  });

  const cards = `<div class="grid">
    <div class="stat"><span>hashrate</span><b>${escape(format.hashrate(rate))}</b></div>
    <div class="stat"><span>rigs</span><b>${mining} mining / ${devices.length}</b></div>
    <div class="stat"><span>online</span><b>${online}</b></div>
    <div class="stat"><span>hottest</span><b>${hot ? escape(format.temperature(hot)) : '-'}</b></div>
  </div>`;

  const list = rigTable(devices, config, now);

  // One row per wallet, because a wallet is the unit the pool pays in. Shown as
  // soon as there is more than one rig: a single rig has nothing to compare.
  const groups = farms.group(devices, config, now);
  const byWallet = devices.length > 1 && groups.length
    ? `<div class="panel"><h3 style="margin-top:0">By wallet</h3>
        <p class="muted small">Every rig mining to the same address is one number at the pool, so it is one
        number here. Rigs that have not reported a wallet are listed last.</p>
        <table>
          <thead><tr><th>wallet</th><th class="num">hashrate</th><th class="num">share</th><th class="num">rigs</th><th class="num">hottest</th><th>state</th></tr></thead>
          <tbody>${groups
            .map((entry) => {
              const share = rate > 0 ? Math.round((entry.rate / rate) * 100) : 0;
              return `<tr>
                <td><code>${escape(entry.label)}</code></td>
                <td class="num">${escape(format.hashrate(entry.rate))}</td>
                <td class="num">${share}%</td>
                <td class="num">${entry.rigs}</td>
                <td class="num">${entry.hottest ? escape(format.temperature(entry.hottest)) : '-'}</td>
                <td>${entry.online ? `${entry.mining} mining, ${entry.online} online` : 'offline'}</td>
              </tr>`;
            })
            .join('')}</tbody>
        </table></div>`
    : '';

  const watch = attention.length
    ? `<div class="panel"><h3 style="margin-top:0">Needs attention</h3><ul class="queue">${attention
        .map((record) => {
          const state = stateOf(record, config, now);
          const why = state === 'offline'
            ? `not seen for ${format.ago(record.last_seen, now).replace(' ago', '')}`
            : state === 'error'
              ? 'the miner reported an error'
              : Number(record.status.temp) >= config.alert_temp
                ? `${format.temperature(record.status.temp)}, at or above the ${config.alert_temp} C alert line`
                : `${record.queue.length} change(s) waiting for the next check-in`;
          return `<li><a href="/rig/${encodeURIComponent(record.id)}">${escape(record.label || record.id)}</a> — ${escape(why)}</li>`;
        })
        .join('')}</ul></div>`
    : '';

  const body = `<h1>Fleet</h1>${cards}${watch}${byWallet}<h2>Rigs</h2>${list}`;
  return page({ title: 'Fleet', active: '/', body, csrf });
}

// ----------------------------------------------------------------------- rigs

function rigs({ store, config, now, csrf }) {
  const { devices } = totals(store, config, now);
  const body = `<h1>Rigs</h1>
    <p class="muted">${devices.length} enrolled · every change is queued and applied on the
    rig's next check-in.</p>
    ${rigTable(devices, config, now)}`;
  return page({ title: 'Rigs', active: '/rigs', body, csrf });
}

// ------------------------------------------------------------------ one rig

function rig({ record, config, now, csrf, flash, flashBad, roster = null }) {
  const status = record.status || {};
  // What the roster says about this rig: the fields it pins, in the order the
  // reconcile module considers them, so the page can explain a value that keeps
  // coming back after somebody changed it here.
  const entry = roster && roster.rigs ? roster.rigs.get(record.id) : null;
  const pinned = entry ? Object.keys(entry.desired || {}) : [];
  const state = stateOf(record, config, now);
  const id = record.id;
  const enc = encodeURIComponent(id);
  // What the rig says it is running, not what somebody once queued: the form
  // prefills with reality, so "the wallet in the box" is the wallet on the rig.
  const desired = {
    wallet: status.wallet || '',
    pool: status.pool || '',
    coin: status.coin || 'xmr',
    mode: status.mode || 'max',
    threads: status.threads && status.threads !== 'auto' ? status.threads : '',
    worker: status.worker || '',
    maxtemp: '',
  };

  const facts = `<dl class="kv">
    <dt>state</dt><dd>${dot(state)}${escape(state)}</dd>
    <dt>hashrate</dt><dd>${escape(format.hashrate(status.hashrate))}${
      Number(status.measured) > 0
        ? ` <span class="muted">· measured ${escape(format.hashrate(status.measured))}</span>`
        : ''
    }</dd>
    <dt>temperature</dt><dd>${escape(format.temperature(status.temp))}</dd>
    <dt>uptime</dt><dd>${escape(format.duration(status.uptime))}</dd>
    <dt>wallet</dt><dd><code>${escape(format.wallet(status.wallet))}</code>${
      walletTag(record) ? ` ${walletTag(record)}` : ''
    }${
      walletTag(record)
        ? `<div class="muted small">${escape(
            address.check(String(status.wallet || '')).ok
              ? 'a stagenet or testnet address - a mainnet pool cannot pay it'
              : `this address fails its checksum: ${address.check(String(status.wallet || '')).reason}. The rig will not start under rx/0.`,
          )}</div>`
        : ''
    }</dd>
    <dt>pool</dt><dd><code>${escape(status.pool || '-')}</code></dd>
    <dt>coin / mode</dt><dd>${escape(status.coin || 'xmr')} · ${escape(status.mode || 'max')} · ${escape(status.threads || 'auto')} threads</dd>
    <dt>version</dt><dd>${escape(status.version || '?')}${status.slot ? ` · slot ${escape(status.slot)}` : ''}</dd>
    <dt>last seen</dt><dd>${escape(format.ago(record.last_seen, now))}</dd>
    <dt>enrolled</dt><dd>${escape(format.ago(record.claimed_at, now))} by ${escape(record.owner || 'nobody')}</dd>
  </dl>`;

  const queued = record.queue.length
    ? `<div class="panel"><h3 style="margin-top:0">Waiting for the next check-in</h3>
        <ul class="queue">${record.queue
          .map((entry) => `<li><code>${escape(entry.cmd)}</code> ${escape(JSON.stringify({ ...entry, id: undefined, at: undefined, cmd: undefined }))}</li>`)
          .join('')}</ul></div>`
    : '';

  const acks = record.acks.length
    ? `<div class="panel"><h3 style="margin-top:0">Last results</h3><ul class="queue">${record.acks
        .slice(-6)
        .reverse()
        .map((entry) => `<li>${entry.ok ? '✅' : '⛔️'} ${escape(entry.cmd || '')} ${entry.ok ? 'applied' : escape(entry.error || 'refused')}
          <span class="muted small">${escape(format.ago(entry.at, now))}</span></li>`)
        .join('')}</ul></div>`
    : '';

  const actions = ['start', 'stop', 'restart', 'update', 'reboot']
    .map((action) => `<form method="post" action="/rig/${enc}/action">${csrfField(csrf)}<input type="hidden" name="action" value="${action}"><button type="submit">${action}</button></form>`)
    .join('');

  // `/log <rig> [n]` exists in the chat, so it exists here: same range, same
  // default, and the answer arrives the same way - with the next check-in.
  const logForm = `<form method="post" action="/rig/${enc}/action" class="inline">
    ${csrfField(csrf)}<input type="hidden" name="action" value="log">
    <input type="number" name="lines" min="5" max="80" value="${Number(config.log_lines) || 40}" aria-label="lines" class="narrow">
    <button type="submit">log</button>
  </form>`;

  const walletForm = `<div class="panel">
    <h3 style="margin-top:0">Wallet</h3>
    <p class="muted small">Validated here and again on the rig: an address the appliance would refuse is never queued.</p>
    <form method="post" action="/rig/${enc}/config">
      ${csrfField(csrf)}
      <label for="wallet">Monero address or subaddress</label>
      <input id="wallet" name="wallet" value="${escape(desired.wallet || '')}" placeholder="4… or 8…" spellcheck="false" autocomplete="off">
      <div class="actions"><button class="primary" type="submit">Queue wallet</button></div>
    </form>
  </div>`;

  const poolForm = `<div class="panel">
    <h3 style="margin-top:0">Pool</h3>
    <form method="post" action="/rig/${enc}/config">
      ${csrfField(csrf)}
      <label for="pool">host:port</label>
      <input id="pool" name="pool" value="${escape(desired.pool || '')}" placeholder="pool.example.org:10001" spellcheck="false" autocomplete="off">
      <div class="actions"><button class="primary" type="submit">Queue pool</button></div>
    </form>
  </div>`;

  const miningForm = `<div class="panel">
    <h3 style="margin-top:0">Mining</h3>
    <form method="post" action="/rig/${enc}/config">
      ${csrfField(csrf)}
      <div class="forms">
        <div><label for="coin">coin</label><select id="coin" name="coin">
          ${Object.keys(COINS).map((key) => `<option value="${key}"${key === (desired.coin || 'xmr') ? ' selected' : ''}>${escape(key)} — ${escape(COINS[key])}</option>`).join('')}
        </select></div>
        <div><label for="mode">mode</label><select id="mode" name="mode">
          ${MODES.map((mode) => `<option value="${mode}"${mode === (desired.mode || 'max') ? ' selected' : ''}>${mode}</option>`).join('')}
        </select></div>
        <div><label for="maxtemp">heat cap, °C (safe only)</label>
          <input id="maxtemp" name="maxtemp" type="number" min="45" max="95" value="${escape(desired.maxtemp || '')}" placeholder="78"></div>
        <div><label for="threads">threads</label>
          <input id="threads" name="threads" value="${escape(desired.threads || '')}" placeholder="auto" inputmode="numeric"></div>
        <div><label for="worker">worker name</label>
          <input id="worker" name="worker" value="${escape(desired.worker || '')}" placeholder="(device id)" autocomplete="off"></div>
      </div>
      <div class="actions"><button class="primary" type="submit">Queue change</button></div>
    </form>
  </div>`;

  const log = record.log
    ? `<div class="panel"><h3 style="margin-top:0">Miner log</h3><pre><code>${escape(record.log)}</code></pre></div>`
    : '';

  const remove = `<div class="panel">
    <h3 style="margin-top:0">Forget this rig</h3>
    <p class="muted small">Removes the enrolment record. The rig keeps mining with its last
    configuration and will appear here again as unclaimed if it keeps checking in.</p>
    <form method="post" action="/rig/${enc}/remove">${csrfField(csrf)}<button class="danger" type="submit">Forget ${escape(record.label || id)}</button></form>
  </div>`;

  const rosterPanel = entry
    ? `<div class="panel"><h3 style="margin-top:0">Pinned by the roster${entry.owner && entry.owner !== record.owner ? ` <span class="muted small">· ${escape(entry.owner)}</span>` : ''}</h3>
        <p class="muted small">${
          pinned.length
            ? `The roster sets <code>${pinned.map(escape).join('</code>, <code>')}</code>. Changing one of them here is applied on the next
               check-in and then corrected again on the check-in after that, because the roster is re-read every minute. To make a
               change stick, change it in <code>FLEET_ROSTER</code> or <code>fleet/roster.json</code>.`
            : 'This rig is in the roster, which decides who owns it and keeps it enrolled across restarts. It pins no settings, so everything below is yours.'
        }</p></div>`
    : '';

  const namePanel = `<div class="panel">
    <h3 style="margin-top:0">Name</h3>
    <p class="muted small">The name is kept here, not on the rig: it is how the page and the chats refer to it.</p>
    <form method="post" action="/rig/${enc}/rename">
      ${csrfField(csrf)}
      <label for="label">rig name</label>
      <input id="label" name="label" value="${escape(record.label || '')}" placeholder="${escape(id)}" autocomplete="off" maxlength="40">
      <div class="actions"><button class="primary" type="submit">Rename</button></div>
    </form>
  </div>`;

  const body = `<p class="muted small"><a href="/rigs">Rigs</a> / ${escape(record.label || id)}</p>
    <h1>${escape(record.label || id)}</h1>
    <p class="muted"><code>${escape(id)}</code></p>
    ${rosterPanel}
    ${facts}
    <div class="actions">${actions}${logForm}</div>
    ${queued}
    ${acks}
    <div class="forms">${walletForm}${poolForm}${namePanel}</div>
    ${miningForm}
    ${log}
    ${remove}`;

  return page({ title: record.label || id, active: '/rigs', body, csrf, flash, flashBad });
}

// ------------------------------------------------------------------- enrol

function enrol({ config, csrf, flash, flashBad, record = null }) {
  const url = config.public_url || `http://localhost:${config.port}`;
  const done = record
    ? `<div class="panel"><h3 style="margin-top:0">Enrolled</h3>
        <p><strong>${escape(record.label || record.id)}</strong> is yours.
        <code>${escape(record.id)}</code></p>
        <p class="muted small">It picks up whatever you queue the next time it checks in,
        which is within ${config.interval} seconds unless the service is asleep.</p>
        <div class="actions"><a href="/rig/${encodeURIComponent(record.id)}"><button type="button" class="primary">Open the rig</button></a></div>
      </div>`
    : '';

  const body = `<h1>Enrol a rig</h1>
    ${done}
    <div class="panel">
      <h3 style="margin-top:0">1. Point the rig here, once</h3>
      <p class="muted small">On the rig's console, or on the kernel command line of a stick
      that boots many machines: <code>zmrig.os.fleet=${escape(url)}</code>.</p>
      <pre><code>zmrig-os fleet --url ${escape(url)}</code></pre>
      <button type="button" data-copy="zmrig-os fleet --url ${escape(url)}">copy</button>
    </div>

    <div class="panel">
      <h3 style="margin-top:0">2. Read the two strings</h3>
      <pre><code>zmrig-os id</code></pre>
      <p class="muted small">The device ID is derived from a key that never leaves the rig.
      The enrolment code is derived from the same key, which is what proves you are standing
      in front of the machine: it cannot be read out of this dashboard or the database.</p>
    </div>

    <div class="panel">
      <h3 style="margin-top:0">3. Type them here</h3>
      <form method="post" action="/enrol">
        ${csrfField(csrf)}
        <div class="forms">
          <div><label for="id">device id</label>
            <input id="id" name="id" placeholder="ZMR-1A2B-3C4D-5E6F" spellcheck="false" autocomplete="off" required></div>
          <div><label for="code">enrolment code</label>
            <input id="code" name="code" placeholder="ABCD-1234" spellcheck="false" autocomplete="off" required></div>
          <div><label for="label">name (optional)</label>
            <input id="label" name="label" placeholder="basement-1" autocomplete="off"></div>
        </div>
        <div class="actions"><button class="primary" type="submit">Enrol</button></div>
      </form>
      <p class="muted small">The rig has to have checked in at least once first, so its
      record exists here. If it has never been seen, the form says so and nothing is created.</p>
    </div>`;

  return page({ title: 'Enrol', active: '/enrol', body, csrf, flash, flashBad });
}

// --------------------------------------------------------------- downloads

function bytes(value) {
  const size = Number(value) || 0;
  if (!size) return '';
  return `${(size / 1048576).toFixed(1)} MB`;
}

function releaseBlock(release, { channel, config, now }) {
  if (!release) {
    return `<div class="panel"><h3 style="margin-top:0">${escape(channel)}</h3>
      <p class="muted">Nothing published on this channel yet, or GitHub could not be reached
      from this host. <a href="https://github.com/MoLik-Labs/ZMRIG/releases">Browse the releases page</a>.</p></div>`;
  }

  const rows = release.assets
    .map((asset) => `<tr>
      <td><a href="${escape(asset.url)}">${escape(asset.name)}</a>
        ${asset.sha256 ? `<div class="muted small"><code>sha256 ${escape(asset.sha256)}</code></div>` : ''}</td>
      <td class="num">${escape(bytes(asset.size))}</td>
      <td class="num muted">${asset.downloads ? escape(asset.downloads) : ''}</td>
    </tr>`)
    .join('');

  return `<div class="panel">
    <h3 style="margin-top:0">${escape(channel)} — ${escape(release.tag)}</h3>
    <p class="muted small">published ${escape(format.ago(new Date(release.published_at).getTime(), now))}</p>
    <table><thead><tr><th>asset</th><th class="num">size</th><th class="num">downloads</th></tr></thead>
    <tbody>${rows}</tbody></table>
  </div>`;
}

function downloads({ releases, config, now, csrf }) {
  const data = releases || { stable: null, beta: null };
  const url = config.public_url || `http://localhost:${config.port}`;

  const body = `<h1>Downloads</h1>
    <p class="muted">Both images are built by CI from the same commit: <code>x86-64-v3</code>
    needs AVX2 (any CPU since about 2015), <code>x86-64-v2</code> runs on everything since
    Nehalem. Every image ships with a <code>.sha256</code> file and the manifest
    <code>zmrig-os update</code> reads.</p>

    ${releaseBlock(data.stable, { channel: 'Stable', config, now })}
    ${releaseBlock(data.beta, { channel: 'Rolling beta', config, now })}

    <div class="panel">
      <h3 style="margin-top:0">Write it and boot it</h3>
      <pre><code>sha256sum -c zmrig-os-*.iso.sha256
sudo dd if=zmrig-os-*.iso of=/dev/sdX bs=4M status=progress conv=fsync</code></pre>
      <p class="muted small">Then point the first boot at this control plane without touching
      the console again:</p>
      <pre><code>zmrig.os.fleet=${escape(url)}
zmrig.os.wallet=4YourAddress…
zmrig.os.install=/dev/nvme0n1   # optional: write it to the disk and be done</code></pre>
    </div>

    <div class="panel">
      <h3 style="margin-top:0">From a shell</h3>
      <pre><code>./scripts/latest-iso.sh --arch v3</code></pre>
      <p class="muted small">Prints the checksum, downloads the image, and never guesses which
      of the two builds your CPU supports — <code>--arch v2</code> if you know it is older.</p>
    </div>`;

  return page({ title: 'Downloads', active: '/downloads', body, csrf });
}

// -------------------------------------------------------------------- docs

function docs({ config, csrf }) {
  const url = config.public_url || `http://localhost:${config.port}`;
  const body = `<h1>API and protocol</h1>
    <p class="muted">This page is the reference for the small surface the control plane
    exposes. The user-facing documentation is
    <a href="https://molik-labs.github.io/ZMRIG/docs/fleet/telegram">on the site</a>.</p>

    <h2>Check-in</h2>
    <p>A rig makes exactly one request, once a minute. It never listens.</p>
    <pre><code>POST /v1/hello
Authorization: Bearer &lt;32-byte key, hex&gt;
Content-Type: application/json

{"device":"ZMR-1A2B-3C4D-5E6F","version":"${VERSION}","status":{…},"acks":[…],"log":null}</code></pre>
    <p>The answer carries whatever was queued, or an empty list:</p>
    <pre><code>{"ok":true,"enrolled":true,"interval":60,"commands":[
  {"id":"k3f9a","cmd":"setup","wallet":"4…","mode":"max"}
]}</code></pre>
    <p class="muted small">The server derives the Device ID and the enrolment code from the key
    on every request, so a rig cannot claim an id that is not its own, and the state file
    only ever holds <code>sha256(key)</code>.</p>

    <h2>Commands a rig applies</h2>
    <table><thead><tr><th>cmd</th><th>fields</th></tr></thead><tbody>
      <tr><td><code>setup</code></td><td><code>wallet</code>, <code>pool</code>, <code>coin</code>, <code>mode</code>, <code>maxtemp</code>, <code>threads</code>, <code>worker</code> — any subset</td></tr>
      <tr><td><code>start</code> <code>stop</code> <code>restart</code></td><td>—</td></tr>
      <tr><td><code>update</code></td><td>— (miner binary, or the spare A/B slot)</td></tr>
      <tr><td><code>log</code></td><td><code>lines</code> (default 80) — comes back in the next check-in</td></tr>
      <tr><td><code>reboot</code></td><td>—</td></tr>
    </tbody></table>

    <h2>Endpoints</h2>
    <table><thead><tr><th>path</th><th>auth</th></tr></thead><tbody>
      <tr><td><code>POST /v1/hello</code></td><td>device key</td></tr>
      <tr><td><code>GET /healthz</code></td><td>public, no fleet data</td></tr>
      <tr><td><code>GET /</code> and the pages here</td><td>session cookie from <code>FLEET_WEB_PASSWORD</code></td></tr>
    </tbody></table>

    <h2>This deployment</h2>
    <dl class="kv">
      <dt>public url</dt><dd><code>${escape(url)}</code></dd>
      <dt>check-in interval</dt><dd>${config.interval} s</dd>
      <dt>offline after</dt><dd>${config.offline_after} s</dd>
      <dt>heat alert</dt><dd>${config.alert_temp} C</dd>
      <dt>queue limit</dt><dd>${config.queue_limit} commands per rig</dd>
      <dt>dashboard</dt><dd>${config.web_enabled ? 'enabled' : 'disabled'}</dd>
    </dl>`;

  return page({ title: 'API', active: '/docs', body, csrf });
}

module.exports = { dashboard, rigs, rig, enrol, downloads, docs, stateOf, totals };
