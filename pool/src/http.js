// HTTP surface: status page for humans, JSON for scripts, Prometheus metrics
// for dashboards. Everything here is read-only.
//
//   GET /                 status page (HTML, no JavaScript required)
//   GET /api/stats        pool + ledger statistics (JSON)
//   GET /api/audit        last N blocks with their exact split (JSON)
//   GET /api/worker/:addr balance, hashrate and every rig for one wallet
//   GET /api/config       the published fee, name and window (JSON)
//   GET /healthz          200 when the pool has a current job
//   GET /metrics          Prometheus text format
//   GET /stratum          WebSocket upgrade (handled by ws.js)

'use strict';

const { formatXmr } = require('./util');

function escapeHtml(text) {
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function formatHashrate(value) {
  if (!Number.isFinite(value) || value <= 0) return '0 H/s';
  if (value >= 1e6) return `${(value / 1e6).toFixed(2)} MH/s`;
  if (value >= 1e3) return `${(value / 1e3).toFixed(2)} kH/s`;

  return `${value.toFixed(0)} H/s`;
}

const STYLE = `
:root{--bg:#0d0f12;--panel:#14171c;--line:#262b34;--text:#e6e9ee;--muted:#9aa4b2;--accent:#f2763f;--ok:#46b17b;--bad:#e2605c}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:960px;margin:0 auto;padding:28px 20px 60px}
h1{font-size:1.6rem;margin:0 0 4px}
h2{font-size:1.05rem;margin:28px 0 10px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;font-weight:600}
.sub{color:var(--muted);margin:0 0 22px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px 16px}
.k{font-size:.76rem;color:var(--muted);text-transform:uppercase;letter-spacing:.05em}
.v{font-size:1.35rem;font-weight:650;font-variant-numeric:tabular-nums;margin-top:4px}
table{width:100%;border-collapse:collapse;font-size:.9rem;background:var(--panel);border:1px solid var(--line);border-radius:10px;overflow:hidden}
th,td{padding:8px 12px;text-align:left;border-bottom:1px solid var(--line)}
th{background:#191d24;font-size:.76rem;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
tr:last-child td{border-bottom:none}
code,pre{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.86rem}
pre{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px 14px;overflow:auto}
a{color:var(--accent)}
.badge{display:inline-block;padding:1px 8px;border-radius:999px;border:1px solid var(--line);font-size:.75rem;color:var(--muted)}
.ok{color:var(--ok);border-color:var(--ok)}
footer{margin-top:40px;color:var(--muted);font-size:.85rem}
`;

function page({ pool, ledger, config }) {
  const stats = pool.status();
  const ledgerStats = ledger.stats();
  const worksInWindow = ledgerStats.sharesInWindow;

  const topRows = (ledgerStats.top || []).map((entry) => `
      <tr><td><code>${escapeHtml(entry.address.slice(0, 12))}…${escapeHtml(entry.address.slice(-6))}</code></td>
      <td class="num">${entry.sharePercent.toFixed(2)}%</td></tr>`).join('');

  return `<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(config.name)} — pool status</title>
<meta name="robots" content="noindex">
<style>${STYLE}</style>
</head><body><div class="wrap">
<h1>${escapeHtml(config.name)}</h1>
<p class="sub">Open, auditable Monero pool · <span class="badge ok">fee ${config.fee_percent}%</span>
<span class="badge">PPLNS ${Math.round(config.pplns_window / 60)} min</span>
<span class="badge">rx/0</span></p>

<div class="grid">
  <div class="card"><div class="k">Pool hashrate</div><div class="v">${formatHashrate(ledgerStats.hashrate)}</div></div>
  <div class="card"><div class="k">Miners</div><div class="v">${stats.miners}</div></div>
  <div class="card"><div class="k">Height</div><div class="v">${stats.height}</div></div>
  <div class="card"><div class="k">Shares accepted</div><div class="v">${stats.accepted}</div></div>
  <div class="card"><div class="k">Blocks</div><div class="v">${ledgerStats.blocks}</div></div>
  <div class="card"><div class="k">Fee collected</div><div class="v">${ledgerStats.feeXmr} XMR</div></div>
</div>

<h2>Connect</h2>
<pre>zmrig -o ${escapeHtml(connectionUrl(config))} -u YOUR_ADDRESS.rig -t 4

# WebSocket/TLS on 443 (works behind restrictive egress):
zmrig -o wss://${escapeHtml(hostOf(config))}${escapeHtml(config.ws_path)} -u YOUR_ADDRESS.rig --tls</pre>

<h2>How the reward is split</h2>
<p class="sub">Every block is split by share difficulty over the last ${Math.round(config.pplns_window / 60)} minutes.
${config.fee_percent}% is the pool fee, published here and in the miner's login reply; the rest is credited
to the miners in the window. Each block is written to <code>/api/audit</code> with the exact numbers, fees included.</p>

<h2>Top miners (window)</h2>
<table><thead><tr><th>Address</th><th class="num">Share</th></tr></thead>
<tbody>${topRows || '<tr><td colspan="2">No shares in the window yet.</td></tr>'}</tbody></table>

<h2>Accounting</h2>
<div class="grid">
  <div class="card"><div class="k">Rewards</div><div class="v">${ledgerStats.rewardXmr}</div></div>
  <div class="card"><div class="k">Paid out</div><div class="v">${ledgerStats.paidXmr}</div></div>
  <div class="card"><div class="k">Pending</div><div class="v">${ledgerStats.pendingXmr}</div></div>
  <div class="card"><div class="k">Shares in window</div><div class="v">${worksInWindow}</div></div>
</div>

<h2>API</h2>
<pre>GET /api/stats        pool, ledger, fee
GET /api/audit        every block and its split
GET /api/worker/ADDR  balance of one address
GET /metrics          Prometheus</pre>

<footer>${escapeHtml(config.name)} · fee ${config.fee_percent}% to
<code>${escapeHtml(config.operator_address.slice(0, 10))}…</code> ·
<a href="/api/stats">stats</a> · <a href="/api/audit">audit</a></footer>
</div></body></html>`;
}

function hostOf(config) {
  return config.public_host || `pool.example.com`;
}

function connectionUrl(config) {
  if (config.public_host) return `${config.public_host}:${config.port}`;

  return `localhost:${config.port}`;
}

function metrics(pool, ledger) {
  const stats = pool.status();
  const ledgerStats = ledger.stats();

  return [
    '# HELP pool_hashrate Pool hashrate from the PPLNS window',
    '# TYPE pool_hashrate gauge',
    `pool_hashrate ${Number(ledgerStats.hashrate) || 0}`,
    '# HELP pool_miners Authorised stratum connections',
    '# TYPE pool_miners gauge',
    `pool_miners ${stats.miners}`,
    '# HELP pool_shares_accepted Total accepted shares',
    '# TYPE pool_shares_accepted counter',
    `pool_shares_accepted ${stats.accepted}`,
    '# HELP pool_shares_rejected Total rejected shares',
    '# TYPE pool_shares_rejected counter',
    `pool_shares_rejected ${stats.rejected}`,
    '# HELP pool_blocks_found Blocks submitted to the daemon',
    '# TYPE pool_blocks_found counter',
    `pool_blocks_found ${stats.blocksFound}`,
    '# HELP pool_fee_percent Published pool fee',
    '# TYPE pool_fee_percent gauge',
    `pool_fee_percent ${Number(pool.config.fee_percent)}`,
    `pool_pending_atomic ${ledgerStats.pendingXmr.replace('.', '')}`,
    '',
  ].join('\n');
}

/** Route a request. Returns true when it was handled. */
async function handle(request, response, { pool, ledger, config }) {
  const url = new URL(request.url, 'http://localhost');
  const path = url.pathname;
  const json = (status, body) => {
    const text = `${JSON.stringify(body, null, 2)}\n`;
    response.writeHead(status, {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'content-length': Buffer.byteLength(text),
    });
    response.end(text);
  };

  // Everything here is read-only. Say so instead of pretending a POST worked.
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    response.writeHead(405, {
      allow: 'GET, HEAD',
      'content-type': 'application/json; charset=utf-8',
      'content-length': Buffer.byteLength('{"error":"method not allowed"}\n'),
    });
    response.end('{"error":"method not allowed"}\n');

    return true;
  }

  if (path === '/healthz') {
    const ok = Boolean(pool.jobs.current);

    return json(ok ? 200 : 503, { ok, height: pool.jobs.current?.height || 0 }), true;
  }

  if (path === '/api/config') {
    return json(200, {
      name: config.name,
      fee_percent: Number(config.fee_percent),
      operator_address: config.operator_address,
      pplns_window: Number(config.pplns_window),
      payout_min: config.payout_min,
      payout_mode: config.payout_mode,
      mode: config.mode,
      ws_path: config.ws_path,
    }), true;
  }

  if (path === '/api/stats') {
    return json(200, {
      pool: pool.status(),
      ledger: ledger.stats(),
      config: {
        name: config.name,
        fee_percent: Number(config.fee_percent),
        pplns_window: Number(config.pplns_window),
        mode: config.mode,
      },
    }), true;
  }

  if (path === '/api/audit') {
    const limit = Math.min(Number(url.searchParams.get('limit')) || 20, 200);

    return json(200, {
      fee_percent: Number(config.fee_percent),
      blocks: ledger.blocks.slice(-limit).reverse(),
      note: 'Every block, its reward, the fee taken and every miner payment. Nothing is rounded away: dust is listed separately.',
    }), true;
  }

  if (path.startsWith('/api/worker/')) {
    // One wallet, every rig behind it. `wallet.rig` or `wallet/rig` also works,
    // because a rig that asks about itself wants the wallet's answer.
    const address = decodeURIComponent(path.slice('/api/worker/'.length));
    const summary = ledger.walletSummary(address);

    return json(summary ? 200 : 404, summary || { error: 'unknown wallet' }), true;
  }

  if (path === '/metrics') {
    const text = metrics(pool, ledger);
    response.writeHead(200, { 'content-type': 'text/plain; version=0.0.4', 'cache-control': 'no-store' });
    response.end(text);

    return true;
  }

  if (path === '/' || path === '/index.html') {
    const text = page({ pool, ledger, config });
    response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    response.end(text);

    return true;
  }

  json(404, { error: 'not found' });

  return true;
}

module.exports = { handle, formatHashrate, escapeHtml, formatXmr };
