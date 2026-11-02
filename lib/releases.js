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
// fetch says "fetch failed" and hides the interesting part in `cause`; the
// difference between a wrong DNS name, a missing CA and a blocked host is the
// difference between three different fixes.
function describe(error) {
  const code = String((error && error.cause && error.cause.code) || (error && error.code) || '');
  const text = String((error && error.message) || error || 'unknown error');
  if (code === 'ENOTFOUND' || code === 'EAI_AGAIN') return 'name lookup failed - check DNS on this host';
  if (code === 'ECONNREFUSED') return 'connection refused - check any proxy or firewall in front of it';
  if (code === 'ETIMEDOUT' || code === 'UND_ERR_CONNECT_TIMEOUT') return 'timed out - the API did not answer in time';
  if (/certificate|self.signed|CERT_/i.test(text) || /CERT_/.test(code)) return 'TLS certificate rejected - set NODE_EXTRA_CA_CERTS if this host intercepts TLS';
  return text;
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
      this.log(`releases: ${why}`);
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
