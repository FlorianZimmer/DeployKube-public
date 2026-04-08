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
  const debug = [];
  const profile = {
    email: process.env.UKC_EMAIL || `${process.env.UKC_USERNAME}@idlab.example`,
    firstName: process.env.UKC_FIRST_NAME || process.env.UKC_USERNAME,
    lastName: process.env.UKC_LAST_NAME || 'User',
  };
  const waitForAny = async (checks, timeoutMs) => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      for (const check of checks) {
        const result = await check();
        if (result) {
          return result;
        }
      }
      await page.waitForTimeout(500);
    }
    return null;
  };
  const transitionTo = async (fragment, loginHost) => {
    const result = await waitForAny([
      async () => {
        const locator = page.locator(`a[href*="${fragment}"]`).first();
        if (await locator.count()) {
          const href = await locator.evaluate((el) => el.href);
          return { kind: 'link', href, page: page.url() };
        }
        return null;
      },
      async () => {
        if (page.url().includes(loginHost) && await page.locator('#username').count()) {
          return { kind: 'login', page: page.url() };
        }
        return null;
      },
    ], 30000);
    if (!result) {
      const body = (await page.locator('body').innerText().catch(() => '')).slice(0, 4000);
      throw new Error(`neither broker link ${fragment} nor login form for ${loginHost} observed; page=${page.url()} body=${body}`);
    }
    debug.push({ step: `transition:${fragment}`, result });
    console.log(JSON.stringify({ step: `transition:${fragment}`, result }));
    if (result.kind === 'link') {
      await page.goto(result.href, { waitUntil: 'domcontentloaded' });
    }
  };
  const maybeCompleteVerifyProfile = async () => {
    if (!page.url().includes('/login-actions/required-action')) {
      return;
    }
    const bodyText = await page.locator('body').innerText();
    if (!bodyText.includes('Update Account Information')) {
      return;
    }
    debug.push({ step: 'ukc-verify-profile', page: page.url() });
    console.log(JSON.stringify({ step: 'ukc-verify-profile', page: page.url() }));
    await page.locator('#email').fill(profile.email);
    await page.locator('#firstName').fill(profile.firstName);
    await page.locator('#lastName').fill(profile.lastName);
    await page.locator('#kc-login').click();
  };
  await page.goto(authUrl);
  console.log(JSON.stringify({ step: 'auth-start', page: page.url() }));
  await transitionTo('/broker/mkc/login', 'mkc-keycloak');
  await transitionTo('/broker/ukc/login', 'ukc-keycloak');
  debug.push({ step: 'ukc-login-form', page: page.url() });
  console.log(JSON.stringify({ step: 'ukc-login-form', page: page.url() }));
  await page.locator('#username').fill(process.env.UKC_USERNAME);
  await page.locator('#password').fill(process.env.UKC_PASSWORD);
  await page.locator('#kc-login').click();
  await page.waitForTimeout(1000);
  await maybeCompleteVerifyProfile();
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
  await fs.writeFile('/proofs/online_token_payload.json', JSON.stringify(payload, null, 2));
  await fs.writeFile('/proofs/online_groups.json', JSON.stringify(groups, null, 2));
  await fs.writeFile('/proofs/online_debug.json', JSON.stringify(debug, null, 2));
  console.log(JSON.stringify({ url: callbackUrl, groups, debug }, null, 2));
  await browser.close();
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
