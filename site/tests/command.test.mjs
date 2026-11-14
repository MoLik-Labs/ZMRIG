// The command builder is the page most likely to hand someone a broken command,
// because it composes a root shell line from form input. These tests call
// `build()` directly with the states the form can produce.
//
// The rules under test are the ones that once produced a wrong command: an
// "automatic" engine that was not automatic, WebSocket on the C++ engine, a TLS
// endpoint without its scheme, a bad wallet that still rendered a copy button.

import test from "node:test";
import assert from "node:assert/strict";

import {
  build,
  hostState,
  shellQuote,
  walletState,
} from "../src/lib/command.mjs";

const WALLET = "46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ";

test("shellQuote leaves safe values alone and quotes the rest", () => {
  assert.equal(shellQuote("rig3"), "rig3");
  assert.equal(shellQuote("a.b:c@d"), "a.b:c@d");
  assert.equal(shellQuote("two words"), "'two words'");
  assert.equal(shellQuote("it's"), "'it'\\''s'");
  assert.equal(shellQuote(""), "''");
  // A command substitution in a rig name must not survive into a root shell.
  assert.equal(shellQuote("$(id)"), "'$(id)'");
});

test("walletState accepts 95 and 106 characters, rejects the rest", () => {
  assert.equal(walletState(WALLET).status, "valid");
  assert.equal(walletState("").status, "empty");
  assert.equal(walletState("4abc").status, "length");
  assert.equal(walletState("0" + WALLET.slice(1)).status, "charset");
  assert.equal(walletState(WALLET + "4").status, "length");
});

test("hostState takes host:port and full pool URLs, rejects junk", () => {
  assert.deepEqual(hostState("pool.example.com:3333"), {
    status: "ok",
    ok: true,
    host: "pool.example.com",
    port: 3333,
  });
  assert.equal(hostState("stratum+tcp://pool.example.com:3333").ok, true);
  assert.equal(hostState("tls://pool.example.com:443/pool").ok, true);
  assert.equal(hostState("pool.example.com").status, "shape");
  assert.equal(hostState("pool.example.com:99999").status, "port");
  assert.equal(hostState("").status, "empty");
});

test("the default answer produces a runnable one-click command", () => {
  const result = build({ wallet: WALLET, pool: "moneroocean" });
  assert.equal(result.blocked, null);
  // The owner is not asserted here: it moved once already, and this test is
  // about the shape of the command. tests/docs/identity.sh is what holds the
  // owner to the git remote.
  assert.match(result.install, /^curl -fsSL https:\/\/raw\.githubusercontent\.com\/[^/]+\/ZMRIG\/BETA\/oneclick\.sh/);
  assert.match(result.install, /install --wallet 46SQLW7D/);
  assert.match(result.install, /--pool gulf\.moneroocean\.stream:10001/);
  assert.ok(result.args.includes("--profile"), result.args.join(" "));
  assert.ok(result.args.includes("free"), result.args.join(" "));
  // --yes is last so nothing after it can be read as an answer to a prompt.
  assert.ok(result.install.endsWith("--yes"), result.install);
});

test("auto profile is throughput-first and the wizard defaults to free", () => {
  const automatic = build({ wallet: WALLET, engine: "auto", profile: "auto" });
  assert.ok(!automatic.args.includes("--engine"), automatic.args.join(" "));
  assert.ok(automatic.args.includes("--profile"), automatic.args.join(" "));
  assert.ok(automatic.args.includes("auto"), automatic.args.join(" "));

  const defaulted = build({ wallet: WALLET });
  assert.ok(defaulted.args.includes("--profile"), defaulted.args.join(" "));
  assert.ok(defaulted.args.includes("free"), defaulted.args.join(" "));
});

test("a fixed engine and profile do emit their flags", () => {
  const result = build({ wallet: WALLET, engine: "xmrig", profile: "watt" });
  assert.ok(result.args.includes("--engine"));
  assert.ok(result.args.includes("xmrig"));
  assert.ok(result.args.includes("--profile"));
  assert.ok(result.args.includes("watt"));
});

test("Cloudflare forces the Zig engine and adds the WebSocket path", () => {
  const result = build({
    wallet: WALLET,
    engine: "xmrig",
    cloudflare: true,
    host: "relay.example.com:443",
    pool: "custom",
  });
  assert.equal(result.engine, "zmrig");
  assert.ok(result.warnings.some((w) => w.key === "engineForced"));
  assert.ok(result.args.includes("--cloudflare"));
  assert.ok(result.args.includes("--ws-path"));
});

test("a proxy also forces the Zig engine", () => {
  const result = build({
    wallet: WALLET,
    engine: "xmrig",
    proxy: true,
    proxyUrl: "socks5://127.0.0.1:1080",
  });
  assert.equal(result.engine, "zmrig");
  assert.ok(result.args.includes("socks5://127.0.0.1:1080"));
});

test("TLS becomes part of the --pool value", () => {
  const result = build({ wallet: WALLET, pool: "supportxmr", tls: true });
  const index = result.args.indexOf("--pool");
  assert.equal(result.args[index + 1], "tls://pool.supportxmr.com:443");
});

test("failover resolves short names and never repeats the primary", () => {
  const result = build({
    wallet: WALLET,
    pool: "moneroocean",
    failover: ["c3pool", "gulf.moneroocean.stream:10001"],
  });
  assert.deepEqual(result.failover, ["c3pool.com:3333"]);
  const index = result.args.indexOf("--failover");
  assert.equal(result.args[index + 1], "c3pool.com:3333");
});

test("copy is blocked on a bad wallet or a bad custom host", () => {
  assert.equal(build({ wallet: "" }).blocked, "wallet-empty");
  assert.equal(build({ wallet: "not-a-wallet" }).blocked, "wallet-invalid");
  assert.equal(
    build({ wallet: WALLET, pool: "custom", host: "no-port" }).blocked,
    "host-invalid"
  );
  assert.equal(
    build({ wallet: WALLET, proxy: true, proxyUrl: "" }).blocked,
    "proxy-missing"
  );
  assert.equal(
    build({ wallet: WALLET, proxy: true, proxyUrl: "proxy.example" }).blocked,
    "proxy-invalid"
  );
  assert.equal(
    build({ wallet: WALLET, connectTo: "203.0.113.10" }).blocked,
    "connect-to-invalid"
  );
});

test("a proxy URL keeps its credentials and a dial address only its host", () => {
  const proxied = build({
    wallet: WALLET,
    proxy: true,
    proxyUrl: "socks5://miner:secret@proxy.example:1080",
  });
  assert.equal(proxied.blocked, null);
  assert.equal(proxied.proxy.scheme, "socks5");
  assert.equal(proxied.proxy.port, 1080);
  const at = proxied.args.indexOf("--proxy");
  assert.equal(proxied.args[at + 1], "socks5://miner:secret@proxy.example:1080");

  const dial = build({ wallet: WALLET, connectTo: "203.0.113.10:3333" });
  assert.equal(dial.blocked, null);
  const idx = dial.args.indexOf("--connect-to");
  assert.equal(dial.args[idx + 1], "203.0.113.10:3333");
});

test("plan uses the same resolution as install and changes nothing", () => {
  const result = build({ wallet: WALLET, pool: "supportxmr", failover: ["c3pool"] });
  assert.match(result.plan, /plan --wallet 46SQLW7D/);
  assert.match(result.plan, /--pool pool\.supportxmr\.com:3333/);
  assert.match(result.plan, /--failover c3pool\.com:3333/);
  assert.ok(typeof result.commands.after === "string");
  assert.match(result.commands.remove, /purge --dry-run/);
});

test("a rig name is quoted, never trusted", () => {
  const result = build({ wallet: WALLET, rig: "rig 1; reboot" });
  assert.match(result.install, /--rig-id 'rig 1; reboot'/);
});

test("a wallet with one wrong character is refused by the page, not by the miner", () => {
  // The page is where the address is pasted, and it used to accept this: every
  // character base58, the right length, one of them wrong. What it produced was
  // a valid-looking command that mines for a week and pays nobody.
  const typo = WALLET.slice(0, 20) + (WALLET[20] === "a" ? "b" : "a") + WALLET.slice(21);
  const state = walletState(typo, "xmr");

  assert.equal(state.status, "checksum");
  assert.equal(state.ok, false);
  assert.match(state.reason, /checksum does not match/);

  // `blocked` is what the page renders as a refusal and what disables the copy
  // button: the command stays visible so the fields it came from can be read,
  // but it cannot be copied with one click.
  const built = build({ wallet: typo, coin: "xmr" });
  assert.equal(built.blocked, "wallet-invalid");

  // The good one still builds, and the page says what was checked.
  assert.equal(build({ wallet: WALLET, coin: "xmr" }).blocked, null);
  assert.match(walletState(WALLET, "xmr").status, /valid/);
});
