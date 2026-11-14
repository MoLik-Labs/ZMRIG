#!/usr/bin/env node
'use strict';

// Is a newer image published?
//
//   docker run --rm ghcr.io/molik-labs/zmrig update --check
//   node deploy/docker/update.js --check --json
//
// Exit codes, deliberately the same shape as `zmrig-os update --check`:
//
//   0   this container is the current release
//   3   a newer release is published (an update is available)
//   2   cannot tell: no network, no token, no such tag. Not an error the rig
//       should act on - a miner keeps mining through a registry outage.
//
// Why the registry and not the running container's digest: a container has no
// Docker socket and asking for one to find out "am I current" would be a
// privileged operation on a machine whose whole job is hashing. A tag lookup is
// an anonymous HTTPS GET against GitHub's own registry, which is also the thing
// that decides whether `docker pull` would fetch anything new.
//
// The tag is resolved the way a pull resolves it: manifest list -> the manifest
// for this architecture -> the config blob -> the `org.opencontainers.image.version`
// label. Comparing tag *names* would be cheaper and wrong, because `latest` is
// allowed to lag behind the newest version tag, and `edge` is not a version at
// all.

const os = require('node:os');

const DEFAULTS = {
  ZMRIG_REGISTRY: 'https://ghcr.io',
  ZMRIG_IMAGE: 'molik-labs/zmrig',
  ZMRIG_TAG: 'latest',
  ZMRIG_TIMEOUT: '10000',
};

const MEDIA = {
  index: [
    'application/vnd.oci.image.index.v1+json',
    'application/vnd.docker.distribution.manifest.list.v2+json',
  ],
  manifest: [
    'application/vnd.oci.image.manifest.v1+json',
    'application/vnd.docker.distribution.manifest.v2+json',
  ],
};

function envOf(env, name, fallback) {
  const value = env[name];
  if (value === undefined || value === null || String(value).trim() === '') return fallback;
  return String(value).trim();
}

function archName(arch = process.arch) {
  if (arch === 'x64') return 'amd64';
  if (arch === 'arm64') return 'arm64';
  return arch;
}

// 6.48.0 > 6.9.0, which string comparison gets wrong. Anything unparseable is
// "not newer": an unknown tag must never turn into an update prompt.
function versionOf(text) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)/.exec(String(text || '').trim());
  if (!match) return null;
  return { major: Number(match[1]), minor: Number(match[2]), patch: Number(match[3]), text: `${match[1]}.${match[2]}.${match[3]}` };
}

function newer(a, b) {
  const left = typeof a === 'string' ? versionOf(a) : a;
  const right = typeof b === 'string' ? versionOf(b) : b;
  if (!left || !right) return false;
  if (left.major !== right.major) return left.major > right.major;
  if (left.minor !== right.minor) return left.minor > right.minor;
  return left.patch > right.patch;
}

// `WWW-Authenticate: Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:molik-labs/zmrig:pull"`
// -> the URL to ask for an anonymous pull token. Public images give one without
// credentials; a private package answers 401 to this too, which is a "cannot
// tell" and not a rig that must stop.
function tokenUrl(header, image) {
  if (!header) return null;
  // Only `Bearer` is worth answering, and only if the realm is a URL: a captive
  // portal or a proxy can answer anything, and a throw here would turn a
  // registry blip into a miner that will not start.
  if (!/^\s*Bearer\b/i.test(header)) return null;

  const realm = /realm="([^"]+)"/.exec(header);
  if (!realm) return null;

  let url;
  try {
    url = new URL(realm[1]);
  } catch {
    return null;
  }
  const service = /service="([^"]+)"/.exec(header);
  if (service) url.searchParams.set('service', service[1]);

  const scope = /scope="([^"]+)"/.exec(header);
  url.searchParams.set('scope', scope ? scope[1] : `repository:${image}:pull`);
  return url.toString();
}

async function getJson(url, headers, timeout) {
  const response = await fetch(url, { headers, signal: AbortSignal.timeout(timeout) });
  const body = response.status === 200 ? await response.json() : null;
  return { status: response.status, headers: response.headers, body };
}

// The registry's own auth dance, done once per run.
async function authorised(base, image, pathname, accept, timeout) {
  const first = await getJson(`${base}${pathname}`, { accept }, timeout);
  if (first.status !== 401) return first;

  const url = tokenUrl(first.headers.get('www-authenticate'), image);
  if (!url) return first;

  const token = await getJson(url, {}, timeout);
  const value = token.body && (token.body.token || token.body.access_token);
  if (!value) return first;

  return getJson(`${base}${pathname}`, { accept, authorization: `Bearer ${value}` }, timeout);
}

// The published release under one tag, or null when it cannot be resolved.
async function resolve(env = process.env, opts = {}) {
  const base = envOf(env, 'ZMRIG_REGISTRY', DEFAULTS.ZMRIG_REGISTRY).replace(/\/+$/, '');
  const image = envOf(env, 'ZMRIG_IMAGE', DEFAULTS.ZMRIG_IMAGE);
  const tag = opts.tag || envOf(env, 'ZMRIG_TAG', DEFAULTS.ZMRIG_TAG);
  const timeout = Number(envOf(env, 'ZMRIG_TIMEOUT', DEFAULTS.ZMRIG_TIMEOUT)) || 10000;
  const arch = archName(opts.arch);

  const top = await authorised(base, image, `/v2/${image}/manifests/${tag}`, MEDIA.index.concat(MEDIA.manifest).join(', '), timeout);
  if (top.status !== 200 || !top.body) return { ok: false, reason: `the registry answered ${top.status} for ${image}:${tag}` };

  const digest = top.headers.get('docker-content-digest') || '';
  let manifest = top.body;

  // An index lists per-platform manifests. The version label lives in the image
  // config, which is one more hop, so a single-arch manifest is taken directly.
  if (Array.isArray(manifest.manifests)) {
    const match = manifest.manifests.find((entry) => entry.platform && entry.platform.architecture === arch && (!entry.platform.os || entry.platform.os === 'linux'));
    if (!match) return { ok: false, reason: `the ${tag} tag has no linux/${arch} manifest` };

    const one = await authorised(base, image, `/v2/${image}/manifests/${match.digest}`, MEDIA.manifest.join(', '), timeout);
    if (one.status !== 200 || !one.body) return { ok: false, reason: `the ${arch} manifest answered ${one.status}` };
    manifest = one.body;
  }

  const configDigest = manifest.config && manifest.config.digest;
  if (!configDigest) return { ok: false, reason: 'the manifest has no config blob' };

  const config = await authorised(base, image, `/v2/${image}/blobs/${configDigest}`, '*/*', timeout);
  const labels = (config.body && config.body.config && config.body.config.Labels) || {};
  const version = versionOf(labels['org.opencontainers.image.version']);

  return {
    ok: true,
    image,
    tag,
    digest,
    arch,
    version: version ? version.text : null,
    revision: labels['org.opencontainers.image.revision'] || null,
    source: labels['org.opencontainers.image.source'] || null,
  };
}

async function check(argv, env = process.env) {
  const json = argv.includes('--json');
  const local = envOf(env, 'ZMRIG_VERSION', '');
  const tag = envOf(env, 'ZMRIG_TAG', DEFAULTS.ZMRIG_TAG);
  const image = envOf(env, 'ZMRIG_IMAGE', DEFAULTS.ZMRIG_IMAGE);

  let remote;
  try {
    remote = await resolve(env, { tag });
  } catch (error) {
    remote = { ok: false, reason: error && error.message ? error.message : String(error) };
  }

  if (!remote.ok) {
    // Offline is not a failure of the rig, so this is a notice on stderr and the
    // exit code that says "cannot tell". A cron job that treats 2 as an error
    // will page someone about a registry blip; the docs say so.
    if (json) console.log(JSON.stringify({ running: local, update: 'unknown', reason: remote.reason }));
    else console.error(`cannot check: ${remote.reason}`);
    return 2;
  }

  const available = remote.version || '';
  const isNewer = local ? newer(available, local) : false;

  if (json) {
    console.log(JSON.stringify({
      running: local || null,
      available: available || null,
      tag,
      image: `ghcr.io/${image}:${tag}`,
      digest: remote.digest || null,
      revision: remote.revision || null,
      update: isNewer ? 'available' : (local ? 'current' : 'unknown'),
    }));
  } else {
    console.log(`${'running'.padEnd(10)}  ${local || '(unknown version)'}`);
    console.log(`${'available'.padEnd(10)}  ${available || '(no version label)'}  (${image}:${tag})`);
    if (isNewer) console.log("run 'zmrig-docker-update --apply' on the host to install it");
    else if (local && available) console.log('this container is current');
  }

  if (!local) return 2;
  return isNewer ? 3 : 0;
}

if (require.main === module) {
  check(process.argv.slice(2)).then((code) => process.exit(code));
}

module.exports = { check, resolve, versionOf, newer, tokenUrl, archName, DEFAULTS };
