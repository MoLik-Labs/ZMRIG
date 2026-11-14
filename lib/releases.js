// The download page needs to know what CI published, and GitHub's API is the
// only source that cannot go stale. It is fetched once, cached, and every
// failure degrades to a link instead of an error: a page that breaks when
// github.com is slow is a page somebody stops opening.
//
// Shared by `fleet/` (the bot's /downloads page) and `serve/` (the web host), so
// there is one implementation of "what is the current image" in the repository.
'use strict';

// Overridable so a test never reaches the real API, and so a self-hosted
// GitHub Enterprise instance can be used by setting GITHUB_API.
const API = 'https://api.github.com';

// What went wrong, in words a reader of the download page can act on. Node's
// fetch says "fetch failed" and hides the interesting part one or two levels
// down in `cause` (and sometimes in `cause.errors`, for the aggregate error it
// builds when every address of a name failed). The difference between a wrong
// DNS name, a missing CA and a blocked host is the difference between three
// different fixes, so this walks the chain instead of printing the wrapper.
const TLS_CODES = new Set([
  'CERT_HAS_EXPIRED',
  'CERT_NOT_YET_VALID',
  'DEPTH_ZERO_SELF_SIGNED_CERT',
  'ERR_TLS_CERT_ALTNAME_INVALID',
  'SELF_SIGNED_CERT_IN_CHAIN',
  'UNABLE_TO_GET_ISSUER_CERT_LOCALLY',
  'UNABLE_TO_VERIFY_LEAF_SIGNATURE',
]);

function causes(error) {
  const out = [];
  let node = error;
  const seen = new Set();
  while (node && typeof node === 'object' && !seen.has(node)) {
    seen.add(node);
    out.push(node);
    const list = Array.isArray(node.errors) ? node.errors : [];
    for (const inner of list) out.push(inner);
    node = node.cause;
  }
  return out;
}

function describe(error) {
  const chain = causes(error);
  const codes = chain.map((item) => String(item.code || '')).filter(Boolean);
  const text = chain.map((item) => String(item.message || '')).join(' | ') || 'unknown error';

  if (codes.some((code) => TLS_CODES.has(code) || /^(CERT_|ERR_TLS_)/.test(code)) || /certificate|self.signed/i.test(text)) {
    return 'TLS certificate rejected - set NODE_EXTRA_CA_CERTS if this network intercepts TLS';
  }
  if (codes.some((code) => code === 'ENOTFOUND' || code === 'EAI_AGAIN')) return 'name lookup failed - check DNS on this host';
  if (codes.includes('ECONNREFUSED')) return 'connection refused - check any proxy or firewall in front of it';
  if (codes.some((code) => code === 'ETIMEDOUT' || code === 'UND_ERR_CONNECT_TIMEOUT')) return 'the API did not answer in time';
  if (codes.includes('ECONNRESET')) return 'the connection was reset before a reply';
  if (codes.includes('UND_ERR_SOCKET')) return 'the connection closed before a reply';
  // Anything else: the deepest message is more useful than "fetch failed".
  const deepest = chain.filter((item) => item.message && item.message !== 'fetch failed').pop();
  return deepest ? String(deepest.message) : String((error && error.message) || error || 'unknown error');
}

class Releases {
  constructor({ repo = 'MoLik-Labs/ZMRIG', ttl = 600_000, fetchImpl = globalThis.fetch, log = () => {}, now = () => Date.now(), agent = 'ZMRIG', api = API } = {}) {
    this.agent = agent;
    this.api = api;
    this.repo = repo;
    this.ttl = ttl;
    this.fetchImpl = fetchImpl;
    this.log = log;
    this.now = now;
    this.cache = { stable: null, beta: null, fetchedAt: 0, error: null };
    this.inflight = null;
    this.shaCache = new Map();
  }

  /** Returns `{stable, beta, fetchedAt, error}`; never throws. */
  async latest() {
    const fresh = this.cache.fetchedAt && this.now() - this.cache.fetchedAt < this.ttl;
    if (fresh) return this.cache;
    if (this.inflight) return this.inflight;

    this.inflight = this.#load().finally(() => {
      this.inflight = null;
    });
    return this.inflight;
  }

  async #load() {
    const stamp = this.now();
    try {
      const response = await this.fetchImpl(`${this.api}/repos/${this.repo}/releases?per_page=12`, {
        headers: { accept: 'application/vnd.github+json', 'user-agent': this.agent },
        signal: AbortSignal.timeout(8000),
      });
      if (!response.ok) throw new Error(`github answered ${response.status}`);
      const releases = await response.json();
      if (!Array.isArray(releases)) throw new Error('unexpected answer');

      const shaped = releases
        .filter((release) => !release.draft)
        .map((release) => ({
          tag: release.tag_name,
          name: release.name,
          prerelease: Boolean(release.prerelease),
          published_at: release.published_at,
          assets: (release.assets || []).map((asset) => ({
            name: asset.name,
            size: asset.size,
            downloads: asset.download_count,
            url: asset.browser_download_url,
            sha256: this.shaCache.get(asset.name) || null,
          })),
        }));

      this.cache = {
        stable: shaped.find((release) => !release.prerelease) || null,
        beta: shaped.find((release) => release.prerelease) || null,
        fetchedAt: stamp,
        error: null,
      };
      this.#fillSha(this.cache.stable).catch(() => {});
      this.#fillSha(this.cache.beta).catch(() => {});
      return this.cache;
    } catch (error) {
      // Keep the last good answer: yesterday's image list is better than an
      // apology when the API rate-limits a shared host. The message is kept even
      // on the first failure — a download page that says "nothing published"
      // when GitHub is unreachable is a page that lies.
      const why = describe(error);
      const error_ = this.cache.fetchedAt
        ? `could not reach GitHub (${why}); showing the last copy`
        : `could not reach GitHub (${why})`;
      this.cache = { ...this.cache, error: error_, fetchedAt: stamp };
      // No prefix here: every caller already names itself ("releases: ..."), and
      // prefixing twice produced "releases: releases: TLS certificate rejected".
      this.log(why);
      return this.cache;
    }
  }

  /** The manifest next to each image carries its sha256 and is a few hundred
   *  bytes, so the page can print a hash to verify against without the reader
   *  downloading 160 MB first. */
  async #fillSha(release) {
    if (!release) return;
    const manifest = release.assets.find((asset) => /zmrig-os-.*\.json$/.test(asset.name));
    const iso = release.assets.find((asset) => asset.name.endsWith('.iso'));
    if (!manifest || !iso || iso.sha256) return;

    const cached = this.shaCache.get(iso.name);
    if (cached) {
      iso.sha256 = cached;
      return;
    }

    const response = await this.fetchImpl(manifest.url, {
      headers: { accept: 'application/octet-stream', 'user-agent': this.agent },
      signal: AbortSignal.timeout(8000),
    });
    if (!response.ok) return;
    const text = await response.text();
    const match = /"iso_sha256"\s*:\s*"([0-9a-f]{64})"/.exec(text) || /"sha256"\s*:\s*"([0-9a-f]{64})"/.exec(text);
    if (!match) return;
    this.shaCache.set(iso.name, match[1]);
    iso.sha256 = match[1];
  }
}

module.exports = { Releases, describe };
