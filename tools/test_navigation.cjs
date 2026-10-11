// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
const assert = require('node:assert/strict');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright-core');

// --- REGION: Check mobile navigation
(async () => {
  const options = { headless: true, args: ['--no-sandbox'] };
  if (process.env.CHROME_PATH) options.executablePath = process.env.CHROME_PATH;
  const browser = await chromium.launch(options);
  try {
    const page = await browser.newPage({ viewport: { width: 375, height: 700 } });
    await page.goto(process.env.WEBSITE_URL || 'http://127.0.0.1:5187');
    const toggle = page.locator('.navbar-toggler');
    const id = await toggle.getAttribute('aria-controls');
    assert.ok(id, 'navigation toggle must name its controlled panel');
    assert.equal(await page.locator('#' + id).count(), 1);
    assert.equal(await toggle.getAttribute('data-bs-target'), '#' + id);
    await toggle.click();
    await page.waitForFunction(panelId => document.querySelector('.navbar-toggler').getAttribute('aria-expanded') === 'true'
      && document.getElementById(panelId).classList.contains('show'), id);
    await toggle.click();
    await page.waitForFunction(panelId => document.querySelector('.navbar-toggler').getAttribute('aria-expanded') === 'false'
      && !document.getElementById(panelId).classList.contains('show')
      && !document.getElementById(panelId).classList.contains('collapsing'), id);
    console.log('PASS: mobile navigation has one target and expands/collapses with correct ARIA state.');
  } finally {
    await browser.close();
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
