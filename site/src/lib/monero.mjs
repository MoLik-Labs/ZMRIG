// The wallet field on the site used to check the alphabet and the length, which
// accepts one wrong character in fifty - on the page where somebody pastes the
// address they are about to mine to.
//
// The decoder is not reimplemented here: it is `lib/address.js`, the same file
// the pool and the bot use, imported as a CommonJS module and wrapped as ESM.
// It was written with `Uint8Array` instead of `Buffer` for exactly this reason,
// so the browser bundle does not need a polyfill and there is one implementation
// of Keccak-256 in the repository rather than two that can disagree.
//
// Only the *shape* of a Monero address is checked by the coin table in
// `command.mjs`; a coin this file does not know still gets the loose alphabet
// check and the warning, because guessing another chain's format would reject
// valid addresses instead of protecting anyone.

import address from "../../../lib/address.js";

/** A real Monero address: right alphabet, right length, right checksum. */
export function isMoneroAddress(text) {
  return BASE.check(String(text || "").trim()).ok;
}

/**
 * What is wrong with this address, or null when nothing is.
 *
 * `status` matches the vocabulary `walletState` already uses, so the page keeps
 * its one branch per case:
 *   checksum - right alphabet and length, wrong checksum (a typo)
 *   network  - a valid address on another chain, which a mainnet pool cannot pay
 */
export function moneroProblem(text) {
  const verdict = BASE.check(String(text || "").trim());
  if (!verdict.ok) {
    // A reason that is about the alphabet or the length is reported by the
    // caller's existing checks; only the checksum is new advice.
    if (/checksum/.test(verdict.reason)) return { status: "checksum", reason: verdict.reason };
    return null;
  }
  if (verdict.net !== "mainnet") {
    return {
      status: "network",
      reason: `this is a ${verdict.net} address, and a mainnet pool cannot pay it`,
    };
  }
  return null;
}

/** The decoded address, for a page that wants to show what it read. */
export function moneroVerdict(text) {
  return BASE.check(String(text || "").trim());
}

// The module is CommonJS (`module.exports`), which is what the pool and the bot
// consume. Node's ESM interop puts it on `default`; webpack does the same.
const BASE = address && address.check ? address : address.default;
