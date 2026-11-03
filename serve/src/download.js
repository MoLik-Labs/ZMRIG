// `/download`, `/api/releases.json` and the three permanent links.
//
// The page is plain HTML with an inline stylesheet: one request, no framework,
// no third-party origin, and it renders in the same shape as the documentation
// around it. Everything it knows about the images comes from the GitHub
// releases API through `lib/releases.js`, and every failure mode still leaves a
// working link on the page.

'use strict';

const { ARCHES } = require('./arches');

function escape(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// Assets come from the GitHub API as absolute URLs. Only http(s) is allowed
// through: a `javascript:` URL in an href is a redirect the page would perform
// on behalf of whoever managed to publish a release.
function safeUrl(value) {
  const text = String(value ?? '');
  if (!/^https?:\/\//i.test(text)) return '#';
  return escape(text);
}

function mib(bytes) {
  if (!bytes) return '';
  return `${(bytes / 1048576).toFixed(1)} MB`;
}

function age(published, now) {
  if (!published) return '';
  const days = Math.floor((now - new Date(published).getTime()) / 86400000);
  if (!Number.isFinite(days) || days < 0) return '';
  if (days === 0) return 'published today';
  if (days === 1) return 'published yesterday';
  if (days < 45) return `published ${days} days ago`;
  return `published ${new Date(published).toISOString().slice(0, 10)}`;
}

function isos(release) {
  if (!release) return [];
  return release.assets
    .filter((asset) => asset.name.endsWith('.iso'))
    .map((asset) => {
      const arch = ARCHES.find((candidate) => asset.name.includes(candidate.name)) || null;
      return { ...asset, arch };
    })
    .sort((a, b) => (b.arch ? b.arch.rank : 0) - (a.arch ? a.arch.rank : 0));
}

function row(asset) {
  const label = asset.arch ? asset.arch.label : '';
  const note = asset.arch ? escape(asset.arch.note) : '';
  return `<tr>
      <td><a class="name" href="${safeUrl(asset.url)}">${escape(asset.name)}</a>
        <div class="sub">${escape(label)}${note ? ` · ${note}` : ''}</div>
        ${asset.sha256 ? `<div class="hash">sha256 ${escape(asset.sha256)}</div>` : ''}</td>
      <td class="num">${escape(mib(asset.size))}</td>
      <td class="num"><a class="button" href="${safeUrl(asset.url)}">Download</a></td>
    </tr>`;
}

function card({ release, title, kind, now, host }) {
  if (!release) {
    return `<section class="card">
      <h2>${escape(title)}</h2>
      <p class="sub">No image has been published on this channel yet. Check
      <a href="https://github.com/MoLik-Labs/ZMRIG/releases">the releases page</a>,
      or build one from source with <code>os/build-iso.sh</code>.</p>
    </section>`;
  }

  const assets = isos(release);
  return `<section class="card">
    <div class="card-head">
      <h2>${escape(title)} <span class="tag ${kind}">${escape(release.tag)}</span></h2>
      <span class="sub">${escape(age(release.published_at, now))}</span>
    </div>
    ${assets.length
      ? `<table><tbody>${assets.map(row).join('')}</tbody></table>`
      : `<p class="sub">This release has no ISO attached yet.</p>`}
    <p class="sub">Every image ships with a <code>.sha256</code> file and a
    <code>.json</code> manifest that <code>zmrig-os update</code> reads.</p>
  </section>`;
}

function styles() {
  return `:root{--bg:#ffffff;--fg:#1c1e21;--muted:#5c6570;--line:#e3e6ea;--accent:#f2763f;--card:#fafbfc;--code:#f4f5f7}
@media (prefers-color-scheme:dark){:root{--bg:#0b0b0c;--fg:#e8e8ea;--muted:#9aa3ad;--line:#24262a;--card:#131416;--code:#1b1d20}}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--fg)}
body{font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
  -webkit-font-smoothing:antialiased}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
header{border-bottom:1px solid var(--line)}
.wrap{max-width:56rem;margin:0 auto;padding:0 1.25rem}
header .wrap{display:flex;align-items:center;gap:1rem;height:3.75rem}
.brand{display:flex;align-items:center;gap:.55rem;font-weight:700;color:var(--fg);letter-spacing:.02em}
.brand svg{display:block}
header nav{margin-left:auto;display:flex;gap:1.1rem;font-size:.9rem}
h1{font-size:2rem;line-height:1.2;margin:2.5rem 0 .4rem}
.lead{color:var(--muted);margin:0 0 2rem;max-width:44rem}
h2{font-size:1.15rem;margin:0}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:1.1rem 1.25rem;margin:0 0 1.25rem}
.card-head{display:flex;align-items:baseline;gap:.75rem;justify-content:space-between;flex-wrap:wrap;margin-bottom:.6rem}
.tag{font:600 .72rem/1 ui-monospace,SFMono-Regular,Menlo,monospace;padding:.28rem .45rem;border-radius:5px;
  background:var(--accent);color:#fff;vertical-align:middle}
.tag.beta{background:var(--muted)}
table{width:100%;border-collapse:collapse}
td{padding:.55rem 0;border-top:1px solid var(--line);vertical-align:top}
tr:first-child td{border-top:0}
.num{text-align:right;white-space:nowrap;color:var(--muted);padding-left:1rem}
.name{font:600 .95rem/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}
.sub{color:var(--muted);font-size:.85rem;margin:.25rem 0 0}
.hash{font:400 .72rem/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--muted);word-break:break-all;margin-top:.3rem}
.button{display:inline-block;border:1px solid var(--line);border-radius:7px;padding:.35rem .8rem;font-size:.85rem;
  font-weight:600;color:var(--fg);background:var(--bg)}
.button:hover{border-color:var(--accent);color:var(--accent);text-decoration:none}
code,pre{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.86em}
code{background:var(--code);padding:.15em .35em;border-radius:4px}
pre{background:var(--code);border:1px solid var(--line);border-radius:8px;padding:.9rem 1rem;overflow:auto}
pre code{background:none;padding:0}
.cols{display:grid;gap:1.25rem;grid-template-columns:1fr}
@media (min-width:52rem){.cols{grid-template-columns:1fr 1fr}}
footer{border-top:1px solid var(--line);margin-top:3rem;color:var(--muted);font-size:.85rem}
footer .wrap{padding:1.5rem 1.25rem}
.notice{border-left:3px solid var(--accent);padding:.1rem 0 .1rem 1rem;color:var(--muted);margin:1.5rem 0}`;
}

function logo() {
  return `<svg width="22" height="22" viewBox="0 0 32 32" aria-hidden="true"><path d="M4 5h24v5l-13 12h13v5H4v-5l13-12H4z" fill="currentColor"/></svg>`;
}

function layout({ title, description, body, host, version }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escape(title)}</title>
<meta name="description" content="${escape(description)}">
<meta name="color-scheme" content="light dark">
<style>${styles()}</style>
</head>
<body>
<header><div class="wrap">
  <a class="brand" href="/">${logo()}ZMRIG</a>
  <nav>
    <a href="/docs/intro">Docs</a>
    <a href="/docs/install/quickstart">Install</a>
    <a href="https://github.com/MoLik-Labs/ZMRIG">GitHub</a>
  </nav>
</div></header>
<main class="wrap">
${body}
</main>
<footer><div class="wrap">
  ${version ? `ZMRIG ${escape(version)} — ` : ''}built by CI from every release, hosted on your own infrastructure.
  ${host ? `Links on this host: <code>${escape(host)}/iso/v3</code>, <code>/iso/v2</code>, <code>/iso/beta</code>.` : ''}
</div></footer>
</body>
</html>`;
}

function page({ data, now = Date.now(), host = '', version = '' }) {
  const stable = data.stable;
  const beta = data.beta;
  const trouble = data.error
    ? `<p class="notice">${escape(data.error)}. The links below are the ones
      published before that happened; if a file is missing, the
      <a href="https://github.com/MoLik-Labs/ZMRIG/releases">releases page</a>
      is the source of truth.</p>`
    : '';

  const body = `<h1>Download ZMRIG OS</h1>
<p class="lead">A bootable image: kernel, read-only root, the miner, a wallet
wizard and four hashrate modes. Write it to a stick and boot it — nothing is
installed and nothing on the stick is modified. Install to disk afterwards with
<code>zmrig-os install</code> if you want it permanent.</p>
${trouble}
${card({ release: stable, title: 'Stable', kind: 'stable', now, host })}
${card({ release: beta, title: 'Beta', kind: 'beta', now, host })}

<div class="cols">
  <section class="card">
    <h2>Write it to a stick</h2>
    <pre><code># replace sdX with the stick, and check it twice
sudo dd if=zmrig-os-*.iso of=/dev/sdX bs=4M status=progress conv=fsync</code></pre>
    <p class="sub">On Windows, Rufus or balenaEtcher. On macOS, <code>dd</code> with
    <code>of=/dev/rdiskN</code>.</p>
  </section>
  <section class="card">
    <h2>Verify, then boot</h2>
    <pre><code>sha256sum -c zmrig-os-*.iso.sha256
# then pass your wallet on the kernel command line,
# or let the wizard ask on the console:
zmrig.os.wallet=4...</code></pre>
    <p class="sub">No account, no telemetry, no remote access to the rig.</p>
  </section>
</div>

<section class="card">
  <h2>Always-current links</h2>
  <p class="sub">These redirect to the newest asset on each channel, so a script
  never has to know the version:</p>
  <pre><code>curl -LO ${escape(host || 'https://your-host')}/iso/v3
curl -LO ${escape(host || 'https://your-host')}/iso/v2
curl -LO ${escape(host || 'https://your-host')}/iso/beta</code></pre>
  <p class="sub">Or use the helper, which picks the variant your CPU supports and
  prints the checksum: <code>scripts/latest-iso.sh</code>.</p>
</section>`;

  return layout({
    title: 'Download ZMRIG OS',
    description: 'The current ZMRIG OS image, its checksum, and permanent links that always point at the newest release.',
    body,
    host,
    version,
  });
}

function payload({ data, now = Date.now() }) {
  const shape = (release) => {
    if (!release) return null;
    return {
      tag: release.tag,
      name: release.name,
      prerelease: release.prerelease,
      published_at: release.published_at,
      assets: release.assets.map((asset) => ({
        name: asset.name,
        url: asset.url,
        size: asset.size,
        downloads: asset.downloads,
        sha256: asset.sha256 || null,
      })),
    };
  };
  return {
    generated_at: new Date(now).toISOString(),
    fetched_at: data.fetchedAt ? new Date(data.fetchedAt).toISOString() : null,
    error: data.error || null,
    stable: shape(data.stable),
    beta: shape(data.beta),
  };
}

/** `/iso/v3` -> the newest ISO for that instruction level, or null. */
function resolve(data, wanted) {
  const channel = wanted === 'beta' ? data.beta : data.stable;
  if (!channel) return null;
  const assets = isos(channel);
  if (!assets.length) return null;
  if (wanted === 'beta') return assets[0];
  const arch = ARCHES.find((candidate) => candidate.slug === wanted);
  if (!arch) return null;
  return assets.find((asset) => asset.arch && asset.arch.slug === wanted) || null;
}

module.exports = { page, payload, resolve, isos, escape, mib };
