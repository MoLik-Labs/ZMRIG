// One password, one cookie.
//
// There are no accounts and no database of users: the password is compared in
// constant time against the one in the environment, and the cookie it mints is
// signed with a key generated at boot. Restarting the service signs everybody
// out, which is the correct behaviour for a single-operator dashboard and saves
// storing a second secret.
//
// The cookie carries its own CSRF token, so a form posted from another origin
// cannot carry a valid one: an attacker's page can make the browser send the
// cookie, but it cannot read it to fill in the field.

'use strict';

const crypto = require('node:crypto');

const COOKIE = 'zmrig_fleet';
const MAX_AGE = 7 * 86400;

function parseCookies(header) {
  const jar = {};
  if (!header) return jar;
  for (const part of String(header).split(';')) {
    const index = part.indexOf('=');
    if (index < 0) continue;
    const name = part.slice(0, index).trim();
    const value = part.slice(index + 1).trim();
    if (name) jar[name] = decodeURIComponent(value);
  }
  return jar;
}

function equal(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  if (left.length !== right.length) return false;
  return crypto.timingSafeEqual(left, right);
}

class Sessions {
  constructor({ password, now = () => Date.now(), maxAge = MAX_AGE }) {
    this.password = String(password || '');
    this.key = crypto.randomBytes(32);
    this.now = now;
    this.maxAge = maxAge;
  }

  /** Constant-time, and it does not leak the length of a wrong guess. */
  check(candidate) {
    const digest = (value) => crypto.createHash('sha256').update(String(value)).digest();
    return equal(digest(candidate), digest(this.password));
  }

  sign(payload) {
    return crypto.createHmac('sha256', this.key).update(payload).digest('base64url');
  }

  issue() {
    const issued = Math.floor(this.now() / 1000);
    const csrf = crypto.randomBytes(16).toString('hex');
    const payload = `${issued}.${csrf}`;
    return { token: `${payload}.${this.sign(payload)}`, csrf, issued };
  }

  verify(token) {
    if (!token || typeof token !== 'string') return null;
    const parts = token.split('.');
    if (parts.length !== 3) return null;
    const [issued, csrf, signature] = parts;
    if (!/^\d+$/.test(issued) || !/^[0-9a-f]{32}$/.test(csrf)) return null;
    if (!equal(signature, this.sign(`${issued}.${csrf}`))) return null;

    const age = Math.floor(this.now() / 1000) - Number(issued);
    if (age < -60 || age > this.maxAge) return null;
    return { csrf, issued };
  }

  cookie(token, { secure = false } = {}) {
    const attributes = [
      `${COOKIE}=${token}`,
      'Path=/',
      'HttpOnly',
      'SameSite=Lax',
      `Max-Age=${this.maxAge}`,
    ];
    if (secure) attributes.push('Secure');
    return attributes.join('; ');
  }

  clear({ secure = false } = {}) {
    const attributes = [`${COOKIE}=`, 'Path=/', 'HttpOnly', 'SameSite=Lax', 'Max-Age=0'];
    if (secure) attributes.push('Secure');
    return attributes.join('; ');
  }

  /** The session behind a request, or null. */
  from(request) {
    return this.verify(parseCookies(request.headers.cookie)[COOKIE]);
  }
}

module.exports = { Sessions, parseCookies, COOKIE };
