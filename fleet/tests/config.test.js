'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { load, validate } = require('../src/config');

test('the operator API token is optional and a weak configured token is refused', () => {
  const disabled = load({});
  assert.equal(disabled.api_token, '');
  assert.ok(validate(disabled).problems.some((problem) => problem.includes('nothing to run')));

  const weak = load({ FLEET_WEB_PASSWORD: 'correct horse battery', FLEET_API_TOKEN: 'short' });
  assert.ok(validate(weak).problems.some((problem) => problem.includes('FLEET_API_TOKEN')));
});

test('a long API token enables the API without changing the dashboard password', () => {
  const apiToken = 'a-securely-long-operator-api-token-123456';
  const config = load({ FLEET_WEB_PASSWORD: 'a long dashboard password', FLEET_API_TOKEN: apiToken });
  assert.equal(config.api_token, apiToken);
  assert.equal(config.web_password, 'a long dashboard password');
  assert.equal(validate(config).problems.length, 0);

  const apiOnly = load({ FLEET_API_TOKEN: apiToken });
  assert.equal(validate(apiOnly).problems.length, 0, 'the authenticated API can be the only fleet surface');
});
