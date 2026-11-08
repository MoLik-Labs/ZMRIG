// The coin matrix and the things built on it: which coins are offered, how the
// ranking behaves when a number is missing, and how the price parser treats a
// response it did not expect.
//
// The rule every test here defends is the same one: a figure nobody measured is
// never presented as an answer. That is why half of these assertions check that
// something is `null` and says why.

import test from "node:test";
import assert from "node:assert/strict";

// Addresses built from real key material, so the checksum cases are real: the
// same helper the pool and the fleet tests use.
import * as monero from "../../tests/common/monero.js";

import {
  ALGOS,
  COINS,
  blocksPerDay,
  coinPerHashDay,
  coinOrDefault,
  findCoin,
  mergePrices,
  priceRequest,
  rankCoins,
} from "../src/lib/coins.mjs";
import { build, walletState } from "../src/lib/command.mjs";

const WALLET = "46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ";
const WOW = "Wo" + "1".repeat(95);

test("every offered coin has an algorithm both engines can hash", () => {
  const algos = Object.keys(ALGOS);
  assert.deepEqual(algos.sort(), [
    "panthera",
    "rx/0",
    "rx/arq",
    "rx/graft",
    "rx/sfx",
    "rx/wow",
    "rx/yada",
  ]);
  assert.equal(COINS.length, 7);
  assert.equal(new Set(COINS.map((coin) => coin.id)).size, 7);
  assert.equal(new Set(COINS.map((coin) => coin.algo)).size, 7);
  for (const coin of COINS) {
    assert.ok(ALGOS[coin.algo], `${coin.id} uses an unknown algorithm`);
    assert.equal(ALGOS[coin.algo].engine, "both");
    assert.ok(coin.why.en.length > 40 && coin.why.vi.length > 40);
    assert.notEqual(coin.why.en, coin.why.vi);
  }
});

test("only Monero ships numbers and pools; everything else starts empty", () => {
  const xmr = findCoin("xmr");
  assert.equal(xmr.pools.length, 7);
  assert.deepEqual(xmr.network, {
    blockTime: 120,
    reward: 0.6,
    hashrate: 4.5e9,
    price: 300,
    cgId: "monero",
  });
  for (const coin of COINS.filter((item) => item.id !== "xmr")) {
    assert.equal(coin.pools.length, 0, `${coin.id} must not ship a pool preset`);
    assert.equal(coin.network.blockTime, null);
    assert.equal(coin.network.reward, null);
    assert.equal(coin.network.hashrate, null);
    assert.equal(coin.network.price, null);
  }
});

test("coinOrDefault never returns undefined", () => {
  assert.equal(coinOrDefault("wow").id, "wow");
  assert.equal(coinOrDefault("nothing").id, "xmr");
  assert.equal(coinOrDefault(undefined).id, "xmr");
});

test("blocksPerDay and coinPerHashDay refuse nonsense instead of guessing", () => {
  assert.equal(blocksPerDay(120), 720);
  assert.equal(blocksPerDay(300), 288);
  assert.equal(blocksPerDay(0), null);
  assert.equal(blocksPerDay("x"), null);

  // 0.6 XMR every 120 s over a 4.5 GH/s network.
  const perHash = coinPerHashDay({
    hashrate: 4.5e9,
    reward: 0.6,
    blockTime: 120,
  });
  assert.ok(Math.abs(perHash - (0.6 * 720) / 4.5e9) < 1e-18);
  assert.equal(coinPerHashDay({ hashrate: 4.5e9, reward: 0, blockTime: 120 }), null);
  assert.equal(coinPerHashDay({ hashrate: 0, reward: 0.6, blockTime: 120 }), null);
  assert.equal(coinPerHashDay({ hashrate: null, reward: 0.6, blockTime: 120 }), null);
});

test("rankCoins ranks what has numbers and names what is missing", () => {
  const { ranked, best, answered } = rankCoins([], 4000);
  assert.equal(answered, 1);
  assert.equal(best.id, "xmr");
  assert.equal(ranked[0].id, "xmr");
  // 4000 H/s × 0.6 × 720 / 4.5e9 × $300
  assert.ok(Math.abs(best.revenueDay - (4000 * 0.6 * 720 * 300) / 4.5e9) < 1e-12);
  assert.deepEqual(
    ranked.slice(1).map((row) => row.revenueDay),
    [null, null, null, null, null, null],
  );
  const wow = ranked.find((row) => row.id === "wow");
  assert.deepEqual(wow.missing, ["reward", "price"]);
  assert.equal(wow.revenueDay, null);
});

test("a filled coin outranks Monero when its numbers say so", () => {
  const { best, ranked } = rankCoins(
    [
      {
        id: "wow",
        reward: "12000",
        blockTime: "300",
        networkHashrate: "600000000",
        price: "1",
      },
    ],
    4000,
  );
  assert.equal(best.id, "wow");
  assert.equal(ranked[0].id, "wow");
  assert.ok(best.revenueDay > ranked.find((row) => row.id === "xmr").revenueDay);
});

test("a per-coin rig hashrate wins over the shared one, and blanks fall back", () => {
  const shared = rankCoins([], 4000).best.revenueDay;
  const own = rankCoins([{ id: "xmr", rigHashrate: "8000" }], 4000).best.revenueDay;
  assert.ok(Math.abs(own - shared * 2) < 1e-12);
  // An empty string is "not answered", not zero.
  const blank = rankCoins([{ id: "xmr", rigHashrate: "" }], 4000).best.revenueDay;
  assert.equal(blank, shared);
});

test("a missing rig hashrate is reported, not treated as zero", () => {
  const { best, ranked } = rankCoins([], 0);
  assert.equal(best, null);
  assert.deepEqual(ranked[0].missing, ["hashrate"]);
  assert.equal(ranked[0].revenueDay, null);
});

test("priceRequest asks for every coin's CoinGecko id at once", () => {
  const request = priceRequest();
  assert.match(request.url, /^https:\/\/api\.coingecko\.com\/api\/v3\/simple\/price\?ids=/);
  assert.match(request.url, /vs_currencies=usd/);
  for (const id of ["monero", "wownero", "arqma", "graft", "safex-cash", "yadacoin", "scala"]) {
    assert.ok(request.ids.includes(id), id);
  }
  assert.equal(request.ids.length, COINS.length);
});

test("mergePrices keeps good numbers and drops everything else", () => {
  const merged = mergePrices({
    monero: { usd: 312.4 },
    wownero: { usd: 0.42 },
    arqma: { eur: 3 },
    graft: { usd: -1 },
    "safex-cash": { usd: "0.01" },
    yadacoin: null,
    scala: { usd: 0.07 },
  });
  assert.deepEqual(merged, [
    { id: "xmr", price: 312.4 },
    { id: "wow", price: 0.42 },
    { id: "xla", price: 0.07 },
  ]);
  assert.deepEqual(mergePrices(null), []);
  assert.deepEqual(mergePrices("nope"), []);
});

test("walletState checks Monero exactly and other coins plausibly", () => {
  assert.equal(walletState(WALLET).status, "valid");
  assert.equal(walletState(WALLET, "xmr").ok, true);

  // A subaddress and an integrated address are built from the real keys rather
  // than by editing characters of a real address: an edited address is exactly
  // the case the checksum now catches, so it would prove the wrong thing.
  assert.equal(walletState(monero.build(42, monero.keysOf(WALLET)), "xmr").status, "valid");
  assert.equal(walletState(monero.integrated(WALLET), "xmr").status, "integrated");

  assert.equal(walletState("0" + WALLET.slice(1)).status, "charset");
  assert.equal(walletState(WALLET + "4", "xmr").status, "length");

  // Right alphabet, right length, wrong checksum: the typo a character count
  // cannot see. It must block, and the message must be about the checksum.
  const typo = walletState(monero.substitute(WALLET, 20), "xmr");
  assert.equal(typo.status, "checksum");
  assert.equal(typo.ok, false);
  assert.match(typo.reason, /checksum/);

  // A valid address on another chain is a real address that mainnet cannot pay.
  const testnet = walletState(monero.onNetwork(WALLET, 53), "xmr");
  assert.equal(testnet.status, "network");
  assert.equal(testnet.ok, false);

  assert.equal(walletState(WOW, "wow").status, "plausible");
  assert.equal(walletState(WOW, "wow").ok, true);
  // Right shape, wrong prefix: usable, but said out loud.
  assert.equal(walletState(WALLET, "wow").status, "prefix");
  assert.equal(walletState(WALLET, "wow").ok, true);
  // No prefix is known for ARQ, so nothing is claimed.
  assert.equal(walletState(WOW, "arq").status, "plausible");
  assert.equal(walletState("", "wow").status, "empty");
});

test("a non-Monero command pins its algorithm and does not reuse a pool preset", () => {
  const wow = build({ coin: "wow", wallet: WOW });
  assert.equal(wow.blocked, "pool-empty");
  const filled = build({
    coin: "wow",
    wallet: WOW,
    pool: "moneroocean",
    host: "pool.wownero.example:7777",
  });
  assert.equal(filled.blocked, null);
  assert.match(filled.install, /--algo rx\/wow/);
  assert.match(filled.install, /pool\.wownero\.example:7777/);
  assert.doesNotMatch(filled.install, /moneroocean/);
  assert.deepEqual(filled.coin, {
    id: "wow",
    name: "Wownero",
    symbol: "WOW",
    algo: "rx/wow",
  });
  assert.ok(filled.notes.some((note) => note.key === "algoPinned"));
});

test("Monero keeps its preset and gains no --algo", () => {
  const xmr = build({ wallet: WALLET, pool: "c3pool" });
  assert.equal(xmr.blocked, null);
  assert.doesNotMatch(xmr.install, /--algo/);
  assert.match(xmr.install, /c3pool\.com:3333/);
  assert.equal(xmr.coin.id, "xmr");
});

test("Panthera is pinned the same way as the RandomX variants", () => {
  const xla = build({
    coin: "xla",
    wallet: WOW,
    pool: "custom",
    host: "pool.scala.example:3333",
  });
  assert.equal(xla.blocked, null);
  assert.match(xla.install, /--algo panthera/);
});
