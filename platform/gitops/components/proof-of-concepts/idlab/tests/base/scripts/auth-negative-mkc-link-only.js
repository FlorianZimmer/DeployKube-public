const fs = require('node:fs/promises');
const { chromium } = require('playwright');

const proofsDir = process.env.PROOFS_DIR || '/proofs';
const kubeNamespace = process.env.K8S_NAMESPACE || 'idlab';
const kubeTokenPath = '/var/run/secrets/kubernetes.io/serviceaccount/token';
const kubeApi = 'https://kubernetes.default.svc';

function adminTokenUrl(baseUrl) {
  return `${baseUrl}/realms/master/protocol/openid-connect/token`;
}

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
  const payload = await fetchJson(adminTokenUrl(baseUrl), {
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

async function adminPut(baseUrl, realm, accessToken, path, body) {
  return fetchJson(`${baseUrl}/admin/realms/${realm}/${path}`, {
    method: 'PUT',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(body),
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

async function ensureRealmUser(baseUrl, realm, accessToken, user) {
  const existing = await adminGet(baseUrl, realm, accessToken, `users?username=${encodeURIComponent(user.username)}`);
  let userId = existing[0]?.id;
  if (!userId) {
    const response = await fetch(`${baseUrl}/admin/realms/${realm}/users`, {
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
      throw new Error(`POST user ${user.username} failed: ${response.status} ${await response.text()}`);
    }
    const created = await adminGet(baseUrl, realm, accessToken, `users?username=${encodeURIComponent(user.username)}`);
    userId = created[0]?.id;
  } else {
    await fetchJson(`${baseUrl}/admin/realms/${realm}/users/${userId}`, {
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
  await adminPut(baseUrl, realm, accessToken, `users/${userId}/reset-password`, {
    type: 'password',
    temporary: false,
    value: user.password,
  });
  return userId;
}

async function deleteUserByUsername(baseUrl, realm, accessToken, username) {
  const users = await adminGet(baseUrl, realm, accessToken, `users?username=${encodeURIComponent(username)}`);
  for (const user of users) {
    await adminDelete(baseUrl, realm, accessToken, `users/${user.id}`);
  }
}

async function kubeToken() {
  return (await fs.readFile(kubeTokenPath, 'utf8')).trim();
}

async function kubePatchScale(tokenValue, deploymentName, replicas) {
  const response = await fetch(`${kubeApi}/apis/apps/v1/namespaces/${kubeNamespace}/deployments/${deploymentName}/scale`, {
    method: 'PATCH',
    headers: {
      Authorization: `Bearer ${tokenValue}`,
      'content-type': 'application/merge-patch+json',
    },
    body: JSON.stringify({ spec: { replicas } }),
  });
  if (!response.ok) {
    throw new Error(`patch scale ${deploymentName}=${replicas} failed: ${response.status} ${await response.text()}`);
  }
}

async function waitForPodCount(tokenValue, labelSelector, expectedCount, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const response = await fetchJson(`${kubeApi}/api/v1/namespaces/${kubeNamespace}/pods?labelSelector=${encodeURIComponent(labelSelector)}`, {
      headers: { Authorization: `Bearer ${tokenValue}` },
    });
    const running = (response.items || []).filter((pod) => pod.status?.phase === 'Running').length;
    if (running === expectedCount) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
  throw new Error(`timed out waiting for ${expectedCount} running pods for ${labelSelector}`);
}

async function getPodLogs(tokenValue, labelSelector) {
  const response = await fetchJson(`${kubeApi}/api/v1/namespaces/${kubeNamespace}/pods?labelSelector=${encodeURIComponent(labelSelector)}`, {
    headers: { Authorization: `Bearer ${tokenValue}` },
  });
  const podName = response.items?.[0]?.metadata?.name;
  if (!podName) {
    return [];
  }
  const logResponse = await fetch(`${kubeApi}/api/v1/namespaces/${kubeNamespace}/pods/${podName}/log?tailLines=200`, {
    headers: { Authorization: `Bearer ${tokenValue}` },
  });
  if (!logResponse.ok) {
    return [];
  }
  const text = await logResponse.text();
  return text.split('\n').filter(Boolean).slice(-40);
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

async function followBrokerLink(page, debug, fragment) {
  const locator = page.locator(`a[href*="${fragment}"]`).first();
  await locator.waitFor({ state: 'visible', timeout: 30000 });
  const href = await locator.evaluate((el) => el.href);
  debug.push({ step: `follow:${fragment}`, page: page.url(), href });
  await page.goto(href, { waitUntil: 'domcontentloaded' });
}

async function main() {
  await fs.mkdir(proofsDir, { recursive: true });

  const ukcUser = {
    username: 'charlie-negative',
    password: 'Charlie-UKC-123!',
    email: 'charlie-negative@idlab.example',
    firstName: 'Charlie',
    lastName: 'Negative',
  };

  const kubeBearer = await kubeToken();
  let browser;
  const debug = [];

  const ukcToken = await token(process.env.UKC_BASE_URL, process.env.UKC_ADMIN_USERNAME, process.env.UKC_ADMIN_PASSWORD);
  const mkcToken = await token(process.env.MKC_BASE_URL, process.env.MKC_ADMIN_USERNAME, process.env.MKC_ADMIN_PASSWORD);
  const btpToken = await token(process.env.BTP_BASE_URL, process.env.BTP_ADMIN_USERNAME, process.env.BTP_ADMIN_PASSWORD);

  try {
    await kubePatchScale(kubeBearer, 'sync-controller', 0);
    await waitForPodCount(kubeBearer, 'app.kubernetes.io/name=sync-controller', 0, 60000);

    const ukcUserId = await ensureRealmUser(process.env.UKC_BASE_URL, 'ukc', ukcToken, ukcUser);
    await deleteUserByUsername(process.env.MKC_BASE_URL, 'mkc', mkcToken, ukcUser.username);
    await deleteUserByUsername(process.env.BTP_BASE_URL, 'btp', btpToken, ukcUser.username);

    const mkcUsers = await adminGet(process.env.MKC_BASE_URL, 'mkc', mkcToken, `users?username=${encodeURIComponent(ukcUser.username)}`);
    const btpUsers = await adminGet(process.env.BTP_BASE_URL, 'btp', btpToken, `users?username=${encodeURIComponent(ukcUser.username)}`);

    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext();
    const page = await context.newPage();
    const redirectUri = 'http://127.0.0.1/callback';
    let callbackUrl = null;
    await context.route(`${redirectUri}**`, async (route) => {
      callbackUrl = route.request().url();
      await route.fulfill({ status: 200, contentType: 'text/plain', body: 'unexpected callback' });
    });

    const authUrl = `${process.env.BTP_BASE_URL}/realms/btp/protocol/openid-connect/auth?client_id=smoke-app&response_type=code&scope=openid&redirect_uri=${encodeURIComponent(redirectUri)}`;
    await page.goto(authUrl);
    debug.push({ step: 'auth-start', page: page.url() });
    await followBrokerLink(page, debug, '/broker/mkc/login');
    await followBrokerLink(page, debug, '/broker/ukc/login');
    debug.push({ step: 'ukc-login-form', page: page.url() });
    await page.locator('#username').fill(ukcUser.username);
    await page.locator('#password').fill(ukcUser.password);
    await page.locator('#kc-login').click();
    await page.waitForTimeout(5000);

    if (callbackUrl) {
      throw new Error(`unexpected callback for non-provisioned MKC user: ${callbackUrl}`);
    }

    const finalUrl = page.url();
    const finalBody = (await page.locator('body').innerText()).slice(0, 4000);
    const failureReason = classifyFailure(finalBody);
    const mkcLogs = await getPodLogs(kubeBearer, 'app.kubernetes.io/name=mkc-keycloak');
    const mkcUsersAfter = await adminGet(process.env.MKC_BASE_URL, 'mkc', mkcToken, `users?username=${encodeURIComponent(ukcUser.username)}`);
    const btpUsersAfter = await adminGet(process.env.BTP_BASE_URL, 'btp', btpToken, `users?username=${encodeURIComponent(ukcUser.username)}`);
    const proof = {
      case: 'ukc-user-not-provisioned-to-mkc',
      expected_result: 'login is refused before token callback because MKC remains link-only for an unprovisioned user',
      preconditions: {
        ukc_user_id: ukcUserId,
        mkc_user_count: mkcUsers.length,
        btp_user_count: btpUsers.length,
        sync_controller_scaled_to_zero: true,
      },
      observed: {
        callback_url: callbackUrl,
        final_url: finalUrl,
        final_body_excerpt: finalBody,
        classified_failure_reason: failureReason,
        browser_trace: debug,
        mkc_log_tail: mkcLogs,
        mkc_user_count_after_attempt: mkcUsersAfter.length,
        btp_user_count_after_attempt: btpUsersAfter.length,
      },
      passed: callbackUrl === null && failureReason !== null && mkcUsersAfter.length === 0 && btpUsersAfter.length === 0,
    };
    await fs.writeFile(`${proofsDir}/negative_mkc_link_only.json`, `${JSON.stringify(proof, null, 2)}\n`);
    console.log(JSON.stringify(proof, null, 2));
    if (!proof.passed) {
      process.exitCode = 1;
    }
  } finally {
    if (browser) {
      await browser.close().catch(() => {});
    }
    await deleteUserByUsername(process.env.BTP_BASE_URL, 'btp', btpToken, ukcUser.username).catch(() => {});
    await deleteUserByUsername(process.env.MKC_BASE_URL, 'mkc', mkcToken, ukcUser.username).catch(() => {});
    await deleteUserByUsername(process.env.UKC_BASE_URL, 'ukc', ukcToken, ukcUser.username).catch(() => {});
    await kubePatchScale(kubeBearer, 'sync-controller', 1).catch(() => {});
    await waitForPodCount(kubeBearer, 'app.kubernetes.io/name=sync-controller', 1, 60000).catch(() => {});
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
