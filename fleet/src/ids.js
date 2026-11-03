// Device identity. No dependencies, and the same arithmetic as the shell tool
// that runs on the rig, so `zmrig-os id` and this file can never disagree about
// what a Device ID is.
//
// The 32-byte secret is generated on the machine and never leaves it. Everything
// the server knows is derived from it:
//
//   ZMR-XXXX-XXXX-XXXX   sha256(secret)[0..6) as hex, upper case
//   enrol code XXXX-XXXX sha256("enroll:" + secret)[0..4) as hex, upper case
//
// A device announces itself by presenting the secret; the server recomputes the
// id and the code from it, so a device cannot claim an id that is not its own,
// and the person enrolling it only has to copy two short strings off the
// console. The code proves that whoever is typing has the machine in front of
// them - it is not a password, and it stops working the moment the secret does.

'use strict';

const crypto = require('node:crypto');

const ID_SHAPE = /^ZMR-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$/;
const SECRET_SHAPE = /^[0-9a-f]{64}$/;
const CODE_SHAPE = /^[0-9A-F]{4}-?[0-9A-F]{4}$/;

function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

/** 48 bits of the secret as the ID a person reads off the console. */
function deviceId(secret) {
  const hex = sha256(secret).slice(0, 12).toUpperCase();
  return `ZMR-${hex.slice(0, 4)}-${hex.slice(4, 8)}-${hex.slice(8, 12)}`;
}

/** The enrolment code, printed next to the ID. Case and dash insensitive. */
function enrolCode(secret) {
  const hex = sha256(`enroll:${secret}`).slice(0, 8).toUpperCase();
  return `${hex.slice(0, 4)}-${hex.slice(4)}`;
}

function normaliseCode(code) {
  const text = String(code || '').toUpperCase().replace(/[^0-9A-F]/g, '');
  return text.length === 8 ? `${text.slice(0, 4)}-${text.slice(4)}` : text;
}

function isDeviceId(text) {
  return typeof text === 'string' && ID_SHAPE.test(text.trim().toUpperCase());
}

function isSecret(text) {
  return typeof text === 'string' && SECRET_SHAPE.test(text);
}

function isCode(text) {
  return typeof text === 'string' && CODE_SHAPE.test(String(text).trim().toUpperCase());
}

/** Constant-time compare of two hex digests, so a wrong code leaks nothing. */
function sameDigest(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const left = Buffer.from(a, 'hex');
  const right = Buffer.from(b, 'hex');
  if (left.length !== right.length || left.length === 0) return false;
  return crypto.timingSafeEqual(left, right);
}

function verifySecret(secret, record) {
  if (!isSecret(secret)) return false;
  if (!record || !record.secret_hash) return false;
  // The id is a function of the secret; recomputing it means a valid secret for
  // device A can never be presented as device B.
  return sameDigest(sha256(secret), record.secret_hash) && deviceId(secret) === record.id;
}

module.exports = {
  deviceId,
  enrolCode,
  normaliseCode,
  isDeviceId,
  isSecret,
  isCode,
  sameDigest,
  sha256,
  verifySecret,
};
