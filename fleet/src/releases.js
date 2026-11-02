// The releases client lives in `lib/` because the web host needs the same
// answers as the bot's download page. This file stays so that every existing
// `require('./releases')` keeps working.

'use strict';

module.exports = require('../../lib/releases');
