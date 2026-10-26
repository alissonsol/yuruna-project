// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42cabe91-b6f2-40a4-a44b-ea8aeb7327c6
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(__dirname + '/test_navigation.cjs', 'utf8');

// --- REGION: run
async function run(env, failure, panelId = 'navbarSupportedContent') {
  const result = { modules: [], closed: 0, clicks: 0, exitCode: 0, errors: [] };
  let expanded = false;
  const toggle = {
    getAttribute: name => ({ 'aria-controls': failure === 'missing-id' ? null : panelId, 'data-bs-target': failure === 'target' ? '#other' : '#' + panelId,
      'aria-expanded': String(expanded) })[name],
    click: async () => { result.clicks++; if (failure !== 'state') expanded = !expanded; }
  };
  const panel = { classList: { contains: name => name === 'show' && (expanded || (failure === 'still-visible' && result.clicks === 2))
    || name === 'collapsing' && failure === 'still-transitioning' && result.clicks === 2 } };
  const page = {
    goto: async url => { result.url = url; },
    locator: selector => selector === '.navbar-toggler' ? toggle : { count: async () => {
      assert.equal(selector, '#' + panelId);
      return failure === 'duplicate' ? 2 : 1;
    } },
    waitForFunction: async (predicate, argument) => { assert.equal(argument, panelId); assert.equal(predicate(argument), true, 'navigation state must change'); }
  };
  const chromium = { launch: async options => {
    result.options = options;
    return { newPage: async options => { result.viewport = options.viewport; return page; }, close: async () => { result.closed++; } };
  } };
  const process = { env, exitCode: 0 };
  await vm.runInNewContext(source, {
    require: name => {
      if (name === 'node:assert/strict') return assert;
      result.modules.push(name);
      return { chromium };
    },
    process,
    console: { log: () => {}, error: error => result.errors.push(error) },
    document: { querySelector: selector => selector === '.navbar-toggler' ? toggle : null,
      getElementById: id => { assert.equal(id, panelId); return panel; } }
  });
  result.exitCode = process.exitCode;
  return result;
}

test('navigation uses portable module resolution and the Playwright browser default', async () => {
  const result = await run({});
  assert.deepEqual(result.modules, ['playwright-core']);
  assert.equal(Object.hasOwn(result.options, 'executablePath'), false);
  assert.equal(result.options.headless, true);
  assert.equal(result.url, 'http://127.0.0.1:5187');
  assert.equal(result.viewport.width, 375);
  assert.equal(result.viewport.height, 700);
  assert.equal(result.clicks, 2);
  assert.equal(result.closed, 1);
  assert.equal(result.exitCode, 0);
});
test('navigation honors explicit module browser and URL overrides without splitting paths', async () => {
  const result = await run({ PLAYWRIGHT_MODULE: '/fixture with spaces/playwright', CHROME_PATH: 'C:\\Program Files\\Chrome\\chrome.exe', WEBSITE_URL: 'http://fixture.invalid/site' });
  assert.deepEqual(result.modules, ['/fixture with spaces/playwright']);
  assert.equal(result.options.executablePath, 'C:\\Program Files\\Chrome\\chrome.exe');
  assert.equal(result.url, 'http://fixture.invalid/site');
  assert.equal(result.exitCode, 0);
});
test('navigation observes the panel named by aria-controls', async () => {
  const result = await run({}, undefined, 'alternateNavigation');
  assert.equal(result.exitCode, 0);
  assert.equal(result.clicks, 2);
  assert.equal(result.closed, 1);
});
for (const failure of ['duplicate', 'target', 'state', 'missing-id', 'still-visible', 'still-transitioning']) {
  test('navigation fails and closes the browser for ' + failure + ' contract violations', async () => {
    const result = await run({}, failure);
    assert.equal(result.exitCode, 1);
    assert.equal(result.errors.length, 1);
    assert.equal(result.closed, 1);
  });
}
