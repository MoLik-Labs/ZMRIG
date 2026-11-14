// Shared with the fleet and the host: one implementation of "is this an address
// a pool can pay", so the miner, the pool and the dashboard cannot disagree.
module.exports = require('../../lib/address');
