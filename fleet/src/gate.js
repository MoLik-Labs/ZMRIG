// Small gates: a rate limiter and nothing else. Kept separate so the command
// tests can construct one without a server.

'use strict';

class RateLimiter {
  constructor(limit, windowSeconds, now = () => Date.now()) {
    this.limit = Math.max(1, limit || 30);
    this.window = Math.max(1, windowSeconds || 60) * 1000;
    this.now = now;
    this.hits = new Map();
  }

  allow(key) {
    const stamp = this.now();
    const history = (this.hits.get(key) || []).filter((at) => stamp - at < this.window);
    if (history.length >= this.limit) {
      this.hits.set(key, history);
      return false;
    }
    history.push(stamp);
    this.hits.set(key, history);
    return true;
  }

  reset() {
    this.hits.clear();
  }
}

module.exports = { RateLimiter };
