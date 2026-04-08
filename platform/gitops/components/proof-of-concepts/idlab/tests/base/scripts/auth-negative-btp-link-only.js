const fs = require('node:fs/promises');
const { chromium } = require('playwright');

const proofsDir = process.env.PROOFS_DIR || '/proofs';

async function fetchJson(url, options = {}) {
  const response = await fetch(url, options);
  const bodyText = await response.text();
  let body;
  try {
    body = bodyText ? JSON.parse(bodyText) : null;
  } catch {
    body = bodyText;
  }
  if (!response.ok) {
    throw new Error(`${options.method || 'GET'} ${url} failed: ${response.status} ${JSON.stringify(body)}`);
  }
  return body;
}

async function token(baseUrl, username, password) {
  const body = new URLSearchParams({
    client_id: 'admin-cli',
    grant_type: 'password',
    username,
    password,
  });
  const payload = await fetchJson(`${baseUrl}/realms/master/protocol/openid-connect/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
  });
  return payload.access_token;
}

async function adminGet(baseUrl, realm, accessToken, path) {
  return fetchJson(`${baseUrl}/admin/realms/${realm}/${path}`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
}

async function adminDelete(baseUrl, realm, accessToken, path) {
  const response = await fetch(`${baseUrl}/admin/realms/${realm}/${path}`, {
    method: 'DELETE',
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!response.ok && response.status !== 404) {
    throw new Error(`DELETE ${baseUrl}/admin/realms/${realm}/${path} failed: ${response.status} ${await response.text()}`);
  }
}

async function deleteUserByUsername(baseUrl, realm, accessToken, username) {
  const users = await adminGet(baseUrl, realm, accessToken, `users?username=${encodeURIComponent(username)}`);
  for (const user of users) {
    await adminDelete(baseUrl, realm, accessToken, `users/${user.id}`);
  }
}

async function ensureMKCLocalUser(baseUrl, accessToken, user) {
  const existing = await adminGet(baseUrl, 'mkc', accessToken, `users?username=${encodeURIComponent(user.username)}`);
  let userId = existing[0]?.id;
  if (!userId) {
    const response = await fetch(`${baseUrl}/admin/realms/mkc/users`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        username: user.username,
        enabled: true,
        email: user.email,
        firstName: user.firstName,
        lastName: user.lastName,
      }),
    });
    if (!response.ok) {
      throw new Error(`POST mkc user ${user.username} failed: ${response.status} ${await response.text()}`);
    }
    const created = await adminGet(baseUrl, 'mkc', accessToken, `users?username=${encodeURIComponent(user.username)}`);
    userId = created[0]?.id;
  } else {
    await fetchJson(`${baseUrl}/admin/realms/mkc/users/${userId}`, {
      method: 'PUT',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        id: userId,
        username: user.username,
        enabled: true,
        email: user.email,
        firstName: user.firstName,
        lastName: user.lastName,
      }),
    });
  }
  await fetchJson(`${baseUrl}/admin/realms/mkc/users/${userId}/reset-password`, {
    method: 'PUT',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      type: 'password',
      temporary: false,
      value: user.password,
    }),
  });
  return userId;
}

function classifyFailure(bodyText) {
  const body = bodyText.toLowerCase();
  const patterns = [
    'unexpected error when authenticating with identity provider',
    'identity provider',
    'invalid username or password',
    'temporarily unavailable',
    'we are sorry',
    'login timeout',
  ];
  return patterns.find((pattern) => body.includes(pattern)) || null;
}

async function main() {
  await fs.mkdir(proofsDir, { recursive: true });

  const mkcUser = {
    username: 'mkc-only-negative',
    password: 'MKC-Only-123!',
    email: 'mkc-only-negative@idlab.example',
    firstName: 'MKC',
    lastName: 'Only',
  };

  let browser;
  const mkcToken = await token(process.env.MKC_BASE_URL, process.env.MKC_ADMIN_USERNAME, process.env.MKC_ADMIN_PASSWORD);
  const btpToken = await token(process.env.BTP_BASE_URL, process.env.BTP_ADMIN_USERNAME, process.env.BTP_ADMIN_PASSWORD);
  try {
    await deleteUserByUsername(process.env.BTP_BASE_URL, 'btp', btpToken, mkcUser.username);
    const mkcUserId = await ensureMKCLocalUser(process.env.MKC_BASE_URL, mkcToken, mkcUser);
    const btpUsers = await adminGet(process.env.BTP_BASE_URL, 'btp', btpToken, `users?username=${encodeURIComponent(mkcUser.username)}`);

    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext();
    const page = await context.newPage();
    const redirectUri = 'http://127.0.0.1/callback';
    let callbackUrl = null;
    await context.route(`${redirectUri}**`, async (route) => {
      callbackUrl = route.request().url();
      await route.fulfill({ status: 200, contentType: 'text/plain', body: 'unexpected callback' });
    });

    const authUrl = `${process.env.BTP_BASE_URL}/realms/btp/protocol/openid-connect/auth?client_id=smoke-app&response_type=code&scope=openid&redirect_uri=${encodeURIComponent(redirectUri)}&kc_idp_hint=mkc`;
    await page.goto(authUrl);
    await page.locator('#username').fill(mkcUser.username);
    await page.locator('#password').fill(mkcUser.password);
    await page.locator('#kc-login').click();
    await page.waitForTimeout(5000);

    if (callbackUrl) {
      throw new Error(`unexpected callback for non-SCIM-provisioned BTP user: ${callbackUrl}`);
    }

    const finalUrl = page.url();
    const finalBody = (await page.locator('body').innerText()).slice(0, 4000);
    const failureReason = classifyFailure(finalBody);
    const btpUsersAfter = await adminGet(process.env.BTP_BASE_URL, 'btp', btpToken, `users?username=${encodeURIComponent(mkcUser.username)}`);
    const proof = {
      case: 'mkc-user-not-scim-provisioned-to-btp',
      expected_result: 'login is refused before token callback because BTP remains link-only for a non-SCIM user',
      preconditions: {
        mkc_user_id: mkcUserId,
        btp_user_count: btpUsers.length,
      },
      observed: {
        callback_url: callbackUrl,
        final_url: finalUrl,
        final_body_excerpt: finalBody,
        classified_failure_reason: failureReason,
        btp_user_count_after_attempt: btpUsersAfter.length,
      },
      passed: callbackUrl === null && failureReason !== null && btpUsersAfter.length === 0,
    };
    await fs.writeFile(`${proofsDir}/negative_btp_link_only.json`, `${JSON.stringify(proof, null, 2)}\n`);
    console.log(JSON.stringify(proof, null, 2));
    if (!proof.passed) {
      process.exitCode = 1;
    }
  } finally {
    if (browser) {
      await browser.close().catch(() => {});
    }
    await deleteUserByUsername(process.env.BTP_BASE_URL, 'btp', btpToken, mkcUser.username).catch(() => {});
    await deleteUserByUsername(process.env.MKC_BASE_URL, 'mkc', mkcToken, mkcUser.username).catch(() => {});
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
