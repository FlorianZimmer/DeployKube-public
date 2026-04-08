const fs = require('node:fs/promises');
const { chromium } = require('playwright');

function decodeJwt(token) {
  const [, payload] = token.split('.');
  return JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();
  const redirectUri = 'http://127.0.0.1/callback';
  let callbackUrl = null;
  const callbackRequest = context.waitForEvent('request', {
    predicate: (request) => request.url().startsWith(redirectUri),
    timeout: 120000,
  }).catch(() => null);
  await context.route(`${redirectUri}**`, async (route) => {
    callbackUrl = route.request().url();
    await route.fulfill({ status: 200, contentType: 'text/plain', body: 'ok' });
  });
  const authUrl = `${process.env.BTP_BASE_URL}/realms/btp/protocol/openid-connect/auth?client_id=smoke-app&response_type=code&scope=openid&redirect_uri=${encodeURIComponent(redirectUri)}&kc_idp_hint=mkc`;
  await page.goto(authUrl);
  if (process.env.EXPECT_NO_UKC_BROKER === 'yes') {
    const brokerVisible = await page.locator('a[href*="/broker/ukc/login"]').count();
    if (brokerVisible > 0) {
      throw new Error('ukc broker link should be hidden while offline mode is active');
    }
  }
  if (await page.locator('text=mkc').count()) {
    await page.locator('text=mkc').click();
  }
  await page.locator('#username').fill(process.env.MKC_USERNAME);
  await page.locator('#password').fill(process.env.MKC_PASSWORD);
  await page.locator('#kc-login').click();
  if (!callbackUrl) {
    const request = await callbackRequest;
    if (request) {
      callbackUrl = request.url();
    }
  }
  if (!callbackUrl) {
    throw new Error(`callback not observed; current page=${page.url()}`);
  }
  const current = new URL(callbackUrl);
  const code = current.searchParams.get('code');
  const tokenResp = await fetch(`${process.env.BTP_BASE_URL}/realms/btp/protocol/openid-connect/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      client_id: 'smoke-app',
      redirect_uri: redirectUri,
      code,
    }),
  });
  const tokens = await tokenResp.json();
  const payload = decodeJwt(tokens.id_token || tokens.access_token);
  const groups = payload.groups || [];
  const expectedGroups = process.env.EXPECTED_GROUPS_JSON
    ? JSON.parse(process.env.EXPECTED_GROUPS_JSON)
    : JSON.parse(await fs.readFile('/proofs/online_groups.json', 'utf8'));
  const diff = JSON.stringify(groups) === JSON.stringify(expectedGroups)
    ? ''
    : `offline=${JSON.stringify(groups)} expected=${JSON.stringify(expectedGroups)}\n`;
  await fs.writeFile('/proofs/offline_token_payload.json', JSON.stringify(payload, null, 2));
  await fs.writeFile('/proofs/offline_groups.json', JSON.stringify(groups, null, 2));
  await fs.writeFile('/proofs/groups_diff.txt', diff);
  console.log(JSON.stringify({ url: callbackUrl, groups, expectedGroups, diff }, null, 2));
  if (diff !== '') {
    process.exit(1);
  }
  await browser.close();
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
