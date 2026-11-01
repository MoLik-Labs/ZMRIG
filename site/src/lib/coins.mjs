// The coins the two engines in this repository can actually mine.
//
// The list is short on purpose. Both miners speak the RandomX family, and the
// C++ engine speaks 34 algorithms, but the Zig engine (the default one) speaks
// these seven. A coin outside this list would mean "use the C++ engine and hope",
// so it is not offered in the builder or the wizard at all.
//
// What is *not* here is as deliberate as what is: pool hostnames for the smaller
// coins. Guessing an endpoint is how a site sends somebody's rig to a dead pool
// for a week, so those coins ask you to paste the address your coin's community
// publishes, and the builder refuses to invent one.
//
// Network numbers (hashrate, block reward, block time) change hourly and cannot
// be fetched at build time from this repository, so only Monero carries defaults —
// they are the same numbers the calculator has always used. Every other coin
// starts empty and says so: fill in the three numbers from the coin's explorer
// and the comparison ranks it. A blank field is honest; an invented one is not.

import { POOLS } from "./pools.mjs";

export const ALGOS = {
  "rx/0": { engine: "both", family: "RandomX" },
  "rx/wow": { engine: "both", family: "RandomWOW" },
  "rx/arq": { engine: "both", family: "RandomARQ" },
  "rx/graft": { engine: "both", family: "RandomGRAFT" },
  "rx/sfx": { engine: "both", family: "RandomSFX" },
  "rx/yada": { engine: "both", family: "RandomYada" },
  panthera: { engine: "both", family: "Panthera" },
};

export const COINS = [
  {
    id: "xmr",
    name: "Monero",
    symbol: "XMR",
    algo: "rx/0",
    address: { prefixes: ["4", "8"], lengths: [95, 106], strict: true },
    network: {
      blockTime: 120,
      reward: 0.6,
      hashrate: 4.5e9,
      price: 300,
      cgId: "monero",
    },
    pools: POOLS.map((pool) => pool.id),
    why: {
      en: "The default and the deepest market: the only coin here with seven pools to choose from, and the one a switching pool settles in. Its tail emission pays 0.6 XMR every 120 seconds, so the reward never drops to zero.",
      vi: "Mặc định và là thị trường sâu nhất: đồng duy nhất ở đây có bảy pool để chọn, và là đồng mà pool chuyển thuật toán quyết toán. Tail emission trả 0,6 XMR mỗi 120 giây nên phần thưởng không bao giờ về 0.",
    },
  },
  {
    id: "wow",
    name: "Wownero",
    symbol: "WOW",
    algo: "rx/wow",
    address: { prefixes: ["Wo"], lengths: [97], strict: false },
    network: {
      blockTime: null,
      reward: null,
      hashrate: null,
      price: null,
      cgId: "wownero",
    },
    pools: [],
    why: {
      en: "A Monero fork with the same privacy model and a much smaller network, so a CPU is a larger share of it. Small networks also mean a reward that moves with every new miner; check today's numbers before you commit a rig.",
      vi: "Bản fork của Monero, cùng mô hình riêng tư nhưng mạng nhỏ hơn nhiều nên một CPU chiếm tỉ lệ lớn hơn. Mạng nhỏ cũng có nghĩa phần thưởng đổi theo từng miner mới; xem số hôm nay trước khi dồn rig vào.",
    },
  },
  {
    id: "arq",
    name: "ArQmA",
    symbol: "ARQ",
    algo: "rx/arq",
    address: { prefixes: [], lengths: [], strict: false },
    network: {
      blockTime: null,
      reward: null,
      hashrate: null,
      price: null,
      cgId: "arqma",
    },
    pools: [],
    why: {
      en: "RandomARQ, a RandomX variant with different tuning. One of the algorithms a switching pool may move a rig to, which is why it is listed even though it has no pool preset here.",
      vi: "RandomARQ, một biến thể RandomX với tham số khác. Đây là một trong những thuật toán mà pool chuyển thuật toán có thể đẩy rig sang, nên nó có mặt dù không có preset pool ở đây.",
    },
  },
  {
    id: "graft",
    name: "Graft",
    symbol: "GRFT",
    algo: "rx/graft",
    address: { prefixes: [], lengths: [], strict: false },
    network: {
      blockTime: null,
      reward: null,
      hashrate: null,
      price: null,
      cgId: "graft",
    },
    pools: [],
    why: {
      en: "RandomGRAFT. Listed for completeness: the network is small and the payout may not be worth a VPS, which the comparison shows once you paste its numbers.",
      vi: "RandomGRAFT. Có mặt cho đầy đủ: mạng nhỏ và phần thưởng có thể không đáng một VPS — bảng so sánh sẽ cho thấy điều đó khi bạn dán số của đồng này.",
    },
  },
  {
    id: "sfx",
    name: "Safex Cash",
    symbol: "SFX",
    algo: "rx/sfx",
    address: { prefixes: [], lengths: [], strict: false },
    network: {
      blockTime: null,
      reward: null,
      hashrate: null,
      price: null,
      cgId: "safex-cash",
    },
    pools: [],
    why: {
      en: "RandomSFX. No pool preset here, so paste the endpoint your pool gives you; the comparison only needs the hashrate and reward its explorer prints.",
      vi: "RandomSFX. Ở đây không có preset pool, nên dán endpoint mà pool của bạn cung cấp; bảng so sánh chỉ cần hashrate và phần thưởng trên explorer của nó.",
    },
  },
  {
    id: "yada",
    name: "YadaCoin",
    symbol: "YDA",
    algo: "rx/yada",
    address: { prefixes: [], lengths: [], strict: false },
    network: {
      blockTime: null,
      reward: null,
      hashrate: null,
      price: null,
      cgId: "yadacoin",
    },
    pools: [],
    why: {
      en: "RandomYada. Included because the engine supports it and a switching pool may pay for it; there is no pool preset and no default price, because there is no number here that would not be a guess.",
      vi: "RandomYada. Có mặt vì engine hỗ trợ và pool chuyển thuật toán có thể trả cho nó; không có preset pool và không có giá mặc định, vì mọi con số ở đây sẽ chỉ là đoán.",
    },
  },
  {
    id: "xla",
    name: "Scala",
    symbol: "XLA",
    algo: "panthera",
    address: { prefixes: [], lengths: [], strict: false },
    network: {
      blockTime: null,
      reward: null,
      hashrate: null,
      price: null,
      cgId: "scala",
    },
    pools: [],
    why: {
      en: "Panthera, the odd one out: not RandomX, but the same kind of CPU work, and both engines hash it. There is no pool preset and no default price — paste both.",
      vi: "Panthera, cái tên lạ nhất: không phải RandomX nhưng cùng kiểu việc cho CPU, và cả hai engine đều băm được. Không có preset pool và không có giá mặc định — hãy dán cả hai.",
    },
  },
];

export const COIN_IDS = COINS.map((coin) => coin.id);

export function findCoin(id) {
  return COINS.find((coin) => coin.id === id) || null;
}

export function coinOrDefault(id) {
  return findCoin(id) || COINS[0];
}

/**
 * Blocks a day for a coin whose block time you know. Monero's 120 s gives the
 * 720 blocks/day the calculator has always used; a 300 s coin gives 288, and
 * using Monero's number for it would overstate the reward by 2.5×.
 */
export function blocksPerDay(blockTimeSeconds) {
  const seconds = Number(blockTimeSeconds);
  if (!Number.isFinite(seconds) || seconds <= 0) return null;
  return 86400 / seconds;
}

/**
 * Coin units mined by 1 H/s in a day, from the network's own numbers.
 * `null` when any input is missing: a made-up reward is worse than a blank row.
 */
export function coinPerHashDay({ hashrate, reward, blockTime }) {
  const blocks = blocksPerDay(blockTime);
  const hash = Number(hashrate);
  const block = Number(reward);
  if (blocks === null || !Number.isFinite(hash) || hash <= 0) return null;
  if (!Number.isFinite(block) || block <= 0) return null;
  return (block * blocks) / hash;
}

/**
 * What one machine earns per day on each coin, with the numbers in front of us.
 *
 * `rows` carries the editable figures the UI keeps — `{id, rigHashrate, reward,
 * blockTime, networkHashrate, price}`. None of them is knowable at build time, so
 * only Monero has defaults; the rest start empty. `defaultHashrate` (H/s) is the
 * rig's hashrate for every coin that has no figure of its own: one rig, seven
 * coins.
 *
 * `network.hashrate` is the network's total and `rigHashrate` is this machine's —
 * separate fields on purpose, because confusing the two ranks coins by how big
 * their network is rather than by what they pay.
 *
 * A row missing a number comes back with `revenueDay: null` and the names of the
 * fields it lacks, never with a zero that would sort last and look like an
 * answer.
 */
export function rankCoins(rows, defaultHashrate) {
  const perCoin = new Map((rows || []).map((row) => [row.id, row]));
  const fallback = Number(defaultHashrate);
  const number = (value) => {
    if (value === "" || value === null || value === undefined) return null;
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  };

  const ranked = COINS.map((coin) => {
    const row = perCoin.get(coin.id) || {};
    const reward = number(row.reward) ?? coin.network.reward;
    const blockTime = number(row.blockTime) ?? coin.network.blockTime;
    const networkHashrate =
      number(row.networkHashrate) ?? coin.network.hashrate;
    const price = number(row.price) ?? coin.network.price;
    const rigHashrate =
      number(row.rigHashrate) ?? (fallback > 0 ? fallback : null);

    const perHashDay = coinPerHashDay({
      hashrate: networkHashrate,
      reward,
      blockTime,
    });
    const complete =
      perHashDay !== null &&
      rigHashrate !== null &&
      rigHashrate > 0 &&
      price !== null &&
      price > 0;

    return {
      id: coin.id,
      name: coin.name,
      symbol: coin.symbol,
      algo: coin.algo,
      rigHashrate,
      network: { reward, blockTime, networkHashrate, price },
      perHashDay,
      coinDay:
        perHashDay === null || rigHashrate === null
          ? null
          : perHashDay * rigHashrate,
      revenueDay: complete ? perHashDay * rigHashrate * price : null,
      missing: [
        perHashDay === null
          ? reward === null || !(reward > 0)
            ? "reward"
            : !(blockTime > 0)
              ? "blockTime"
              : "network"
          : null,
        !(rigHashrate !== null && rigHashrate > 0) ? "hashrate" : null,
        !(price !== null && price > 0) ? "price" : null,
      ].filter(Boolean),
    };
  });

  const sortable = ranked.filter((row) => row.revenueDay !== null);
  sortable.sort((a, b) => b.revenueDay - a.revenueDay);
  const rest = ranked.filter((row) => row.revenueDay === null);
  return {
    ranked: [...sortable, ...rest],
    best: sortable[0] || null,
    answered: sortable.length,
  };
}

/** The URL a browser would ask for prices, or null when no coin has an id. */
export function priceRequest(coins = COINS) {
  const ids = coins.map((coin) => coin.network?.cgId).filter(Boolean);
  if (ids.length === 0) return null;
  return {
    url:
      "https://api.coingecko.com/api/v3/simple/price?ids=" +
      encodeURIComponent(ids.join(",")) +
      "&vs_currencies=usd",
    ids,
  };
}

/**
 * Fold a CoinGecko answer into price rows. Pure, so the parsing is tested with a
 * literal instead of the network: `{monero: {usd: 312.4}}` → `[{id:"xmr", price:312.4}]`.
 * An id the API did not answer is simply absent from the result.
 */
export function mergePrices(payload, coins = COINS) {
  const out = [];
  if (!payload || typeof payload !== "object") return out;
  for (const coin of coins) {
    const cgId = coin.network?.cgId;
    if (!cgId) continue;
    const usd = payload[cgId]?.usd;
    if (typeof usd === "number" && Number.isFinite(usd) && usd > 0) {
      out.push({ id: coin.id, price: usd });
    }
  }
  return out;
}
