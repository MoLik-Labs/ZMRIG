// Turning a set of choices into the exact command `oneclick.sh` receives.
//
// Pure on purpose: no DOM, no storage, no clock. The builder renders the
// result, and the tests call `build()` directly with the states the form can
// produce, so the page and the tests agree on what a given answer means.
//
// Messages are returned as keys, not sentences. The component translates them;
// the tests assert behaviour, not prose.
//
// Rules encoded here, each one a bug or a near miss at some point:
//   * `--engine auto` lets the installer decide. The throughput-first profile
//     is explicit so battery state can never silently lower hashrate.
//   * The C++ engine has no WebSocket client and no proxy support. Asking for
//     either forces zmrig instead of writing a config nothing can run.
//   * A TLS pool is `tls://host:port`; the scheme is part of the value, because
//     that is what `oneclick.sh` parses.
//   * Everything user-supplied goes through shellQuote. A rig name is typed by
//     a human and pasted into a root shell.

import { POOLS, findPool } from "./pools.mjs";
import { COINS, coinOrDefault, findCoin } from "./coins.mjs";
import { moneroProblem } from "./monero.mjs";

export const RAW_URL =
  "https://raw.githubusercontent.com/MoLik-Labs/ZMRIG/BETA/oneclick.sh";

const SAFE = /^[A-Za-z0-9._:@%+=,/\-]+$/;

export function shellQuote(value) {
  if (value === "") return "''";
  if (SAFE.test(value)) return value;
  return "'" + String(value).replace(/'/g, "'\\''") + "'";
}

// CryptoNote addresses are base58: no 0, O, I or l. Monero's are exact — 95
// characters starting with 4 (primary) or 8 (subaddress), 106 for an integrated
// address — and they carry a four-byte Keccak-256 checksum, which `monero.mjs`
// verifies with the same decoder the pool and the bot use. That matters most
// here: this is the first place a wallet is pasted, and a character count accepts
// one typo in fifty. The other coins get the checks this file can be sure of
// (alphabet, plausible length) plus a prefix *warning* when the coin's prefix is
// known: a wrong prefix is worth saying out loud, but blocking somebody's valid
// address because this file guessed a prefix wrongly would be worse than the
// miss. Their pools check the checksum; nothing here pretends to.
const BASE58 = /^[1-9A-HJ-NP-Za-km-z]+$/;

// Monero only: the checksum, decoded. `moneroProblem` returns null for anything
// that is wrong for a reason the checks below already describe.
function checksumProblem(text, coinId) {
  if (coinId !== "xmr" && coinId !== "monero") return null;
  return moneroProblem(text);
}

export function walletState(value, coin) {
  const text = String(value || "").trim();
  const c = typeof coin === "string" ? coinOrDefault(coin) : coin || COINS[0];
  const rule = c.address || {};
  if (!text) return { status: "empty", ok: false, length: 0, coin: c.id };
  if (!BASE58.test(text)) {
    return { status: "charset", ok: false, length: text.length, coin: c.id };
  }

  if (rule.strict) {
    // The decoder knows more than the prefix table does, so it is asked first:
    // a stagenet address is a real address on another chain, and saying "this
    // starts with the wrong character" would send its owner looking for a typo
    // that is not there. Both refusals below are about the checksum, which is
    // the failure a character count cannot see and a payout cannot survive.
    const checksum = checksumProblem(text, c.id);
    if (checksum && rule.lengths.includes(text.length)) {
      return { status: checksum.status, ok: false, length: text.length, coin: c.id, reason: checksum.reason };
    }

    if (
      rule.prefixes &&
      !rule.prefixes.some((prefix) => text.startsWith(prefix))
    ) {
      return { status: "prefix", ok: false, length: text.length, coin: c.id };
    }

    if (rule.lengths.includes(95) && text.length === 95) {
      return { status: "valid", ok: true, length: 95, coin: c.id };
    }
    if (rule.lengths.includes(106) && text.length === 106) {
      return { status: "integrated", ok: true, length: 106, coin: c.id };
    }
    return { status: "length", ok: false, length: text.length, coin: c.id };
  }

  // Loose rule: CryptoNote addresses live in this range; outside it the string is
  // not an address at all.
  if (text.length < 90 || text.length > 120) {
    return { status: "length", ok: false, length: text.length, coin: c.id };
  }
  const wrongPrefix =
    rule.prefixes &&
    rule.prefixes.length > 0 &&
    !rule.prefixes.some((prefix) => text.startsWith(prefix));
  return {
    status: wrongPrefix ? "prefix" : "plausible",
    ok: true,
    length: text.length,
    coin: c.id,
  };
}

// `host:port`, with an optional scheme. A pool URL pasted from a provider page
// is `stratum+tcp://host:3333`, and rejecting that would be a needless round
// trip. The value ends up in a URL and in a JSON file, so no spaces.
// `http://user:pass@host:port` or `socks5://host:port`. The installer passes the
// value straight to the miner, which refuses anything else, so the builder
// refuses it first rather than handing over a command that cannot connect.
export function proxyState(value) {
  const text = String(value || "").trim();
  if (!text) return { status: "empty", ok: false };
  const match =
    /^(https?|socks5h?):\/\/(?:[^@\s/]+@)?([^\s:/]+):(\d{1,5})\/?$/i.exec(text);
  if (!match) return { status: "shape", ok: false };
  const port = Number(match[3]);
  if (!(port > 0 && port < 65536)) return { status: "port", ok: false, port };
  return {
    status: "ok",
    ok: true,
    scheme: match[1].toLowerCase(),
    host: match[2],
    port,
  };
}

export function hostState(value) {
  const text = String(value || "").trim();
  if (!text) return { status: "empty", ok: false };

  const match =
    /^(?:(?:tls|stratum\+ssl|stratum\+tcp|stratum|wss?):\/\/)?([^\s:/]+):(\d{1,5})\/?([^\s]*)$/i.exec(
      text,
    );
  if (!match) return { status: "shape", ok: false };

  const port = Number(match[2]);
  if (!(port > 0 && port < 65536)) return { status: "port", ok: false, port };

  return { status: "ok", ok: true, host: match[1], port };
}

function normalise(state) {
  const s = state || {};
  return {
    coin: findCoin(String(s.coin || "xmr")) ? String(s.coin || "xmr") : "xmr",
    wallet: String(s.wallet || "").trim(),
    rig: String(s.rig || "")
      .trim()
      .slice(0, 32),
    engine: s.engine === "xmrig" || s.engine === "zmrig" ? s.engine : "auto",
    profile: s.profile === "watt" || s.profile === "auto" ? s.profile : "free",
    pool: String(s.pool || "moneroocean"),
    host: String(s.host || "").trim(),
    failover: (s.failover || []).filter(Boolean),
    tls: Boolean(s.tls),
    cloudflare: Boolean(s.cloudflare),
    wsPath: String(s.wsPath || "/stratum").trim() || "/stratum",
    proxy: Boolean(s.proxy),
    proxyUrl: String(s.proxyUrl || "").trim(),
    connectTo: String(s.connectTo || "").trim(),
    msr: Boolean(s.msr),
    nicehash: Boolean(s.nicehash),
    notune: Boolean(s.notune),
    autotuneOff: Boolean(s.autotuneOff),
    noHealthRestart: Boolean(s.noHealthRestart),
    force: Boolean(s.force),
    clone: Boolean(s.clone),
    cpu: Number(s.cpu),
  };
}

function quoteArgs(args) {
  return args.map((arg) => (/^--/.test(arg) ? arg : shellQuote(arg))).join(" ");
}

export function build(state) {
  const s = normalise(state);
  const coin = coinOrDefault(s.coin);
  // Pool presets exist for Monero only. For every other coin `known` is null and
  // the endpoint has to be typed, which is the honest default: this repository
  // knows the Monero pools' fees and endpoints, and does not know the others'.
  const presetAllowed = coin.pools.length > 0;
  const known = presetAllowed ? findPool(s.pool) : null;
  const isCustom = !known;

  const host = s.host || (known ? known.host : "");
  const wallet = walletState(s.wallet, coin);
  const hostCheck = hostState(host);
  const connectCheck = s.connectTo ? hostState(s.connectTo) : null;
  const proxyCheck = s.proxy ? proxyState(s.proxyUrl) : null;

  const notes = [];
  const warnings = [];
  let blocked = null;

  // --- what the pool endpoint becomes -------------------------------------
  let endpoint = "";
  if (!isCustom && s.tls && known && known.tlsHost) {
    endpoint = "tls://" + known.tlsHost;
    notes.push({ key: "tls443" });
  } else if (!isCustom && s.tls && known && !known.tlsHost) {
    endpoint = "tls://" + known.host;
    warnings.push({ key: "noTlsPort", params: { pool: known.name } });
  } else if (isCustom) {
    endpoint = s.host;
  } else {
    endpoint = known.host;
  }

  const failover = [];
  for (const name of s.failover) {
    const other = findPool(name);
    const value = other ? other.host : name;
    if (value && value !== endpoint) failover.push(value);
  }

  // --- engine and flags ----------------------------------------------------
  let engine = s.engine;
  if ((s.cloudflare || s.proxy || s.connectTo) && engine === "xmrig") {
    engine = "zmrig";
    warnings.push({ key: "engineForced" });
  }

  if (known && known.switching && engine === "zmrig") {
    warnings.push({ key: "switchingPool", params: { pool: known.name } });
  }
  if (coin.id !== "xmr") {
    notes.push({
      key: "algoPinned",
      params: { algo: coin.algo, coin: coin.name },
    });
  }

  const args = ["install", "--wallet", s.wallet || "YOUR_WALLET"];
  if (s.rig) args.push("--rig-id", s.rig);
  if (engine !== "auto") args.push("--engine", engine);
  args.push("--pool", endpoint || "YOUR_POOL_HOST");
  // Monero is left alone: pinning rx/0 on a switching pool would stop it from
  // moving the rig to whichever RandomX coin pays best, which is the whole
  // point of that pool. Every other coin is pinned to its own algorithm.
  if (coin.algo !== "rx/0") args.push("--algo", coin.algo);
  if (failover.length) args.push("--failover", failover.join(","));

  if (s.cloudflare) {
    args.push("--cloudflare");
    const wsPath = s.wsPath[0] === "/" ? s.wsPath : "/" + s.wsPath;
    args.push("--ws-path", wsPath);
  }

  args.push("--profile", s.profile);
  if (s.proxy) args.push("--proxy", s.proxyUrl || "socks5://127.0.0.1:9050");
  if (s.connectTo) args.push("--connect-to", s.connectTo);
  // MSR is written by default on a root install; the flag exists for hosts
  // that refuse the write (most VMs and containers).
  if (s.msr) args.push("--no-msr");
  if (s.nicehash) args.push("--nicehash");
  if (Number.isFinite(s.cpu) && s.cpu > 0 && s.cpu < 100) {
    args.push("--cpu-hint", String(Math.round(s.cpu)));
  }
  if (s.autotuneOff) args.push("--no-autotune");
  if (s.notune) args.push("--no-tune");
  if (s.noHealthRestart) args.push("--no-health-restart");
  if (s.force) args.push("--force");
  args.push("--yes");

  const install = s.clone
    ? `sudo ./oneclick.sh ${quoteArgs(args)}`
    : `curl -fsSL ${RAW_URL} \\\n  | sudo bash -s -- ${quoteArgs(args)}`;

  // A preview that touches nothing: same pool resolution and same config, no
  // build, no service. This is the honest "what will happen" button.
  const planArgs = ["plan"];
  if (s.wallet) planArgs.push("--wallet", s.wallet);
  planArgs.push("--pool", endpoint || "YOUR_POOL_HOST");
  if (coin.algo !== "rx/0") planArgs.push("--algo", coin.algo);
  if (failover.length) planArgs.push("--failover", failover.join(","));
  if (engine !== "auto") planArgs.push("--engine", engine);
  planArgs.push("--profile", s.profile);

  const plan = s.clone
    ? `sudo ./oneclick.sh ${quoteArgs(planArgs)}`
    : `curl -fsSL ${RAW_URL} \\\n  | sudo bash -s -- ${quoteArgs(planArgs)}`;

  // --- state that must block the copy button -------------------------------
  if (!wallet.ok)
    blocked = wallet.status === "empty" ? "wallet-empty" : "wallet-invalid";
  else if (isCustom && !hostCheck.ok)
    blocked = hostCheck.status === "empty" ? "pool-empty" : "host-invalid";
  else if (s.proxy && !s.proxyUrl) blocked = "proxy-missing";
  else if (s.proxy && !proxyCheck.ok) blocked = "proxy-invalid";
  else if (s.connectTo && !connectCheck.ok) blocked = "connect-to-invalid";

  if (s.notune) notes.push({ key: "notune" });
  if (s.autotuneOff) notes.push({ key: "autotuneOff" });
  if (s.noHealthRestart) notes.push({ key: "noHealthRestart" });
  if (s.profile === "watt") notes.push({ key: "profileWatt" });
  if (s.profile === "free") notes.push({ key: "profileFree" });

  return {
    args,
    flags: args.filter((arg) => arg.startsWith("--")),
    coin: {
      id: coin.id,
      name: coin.name,
      symbol: coin.symbol,
      algo: coin.algo,
    },
    wallet,
    host: hostCheck,
    connectTo: connectCheck,
    proxy: proxyCheck,
    pool: {
      id: isCustom ? "custom" : known.id,
      name: isCustom ? null : known.name,
      endpoint,
      fee: known ? known.fee : null,
      switching: known ? known.switching : null,
    },
    failover,
    engine,
    profile: s.profile,
    install,
    plan,
    commands: {
      install,
      plan,
      // Commands only, no commentary: this block is meant to be selected and
      // pasted, and a shell comment inside it would be pasted too. The headings
      // above the blocks are translated; these lines are not prose.
      after: [
        "sudo systemctl status zmrig --no-pager -l",
        "sudo journalctl -u zmrig -n 40 --no-pager",
        "sudo ./oneclick.sh report --power 0",
      ].join("\n"),
      remove: [
        "sudo ./oneclick.sh purge --dry-run",
        "sudo ./oneclick.sh purge",
      ].join("\n"),
    },
    notes,
    warnings,
    blocked,
  };
}

export const POOL_IDS = POOLS.map((pool) => pool.id);
