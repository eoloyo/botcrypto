// login.js <wallet-id> [shots-dir] — one end-user login to a Simpl agent's Keycloak with a wallet.
//
// A headless browser plays the user at the agent (Keycloak realm `authority`, client `lab-app`); the
// walt.id wallet API plays the user's phone. Steps: open the agent login page -> choose
// "Verifiable Credentials" (Simpl's OpenID4VP identity provider) -> read the openid4vp:// request the page
// shows as a QR code -> the wallet answers it -> the page's polling sees the verified presentation and
// Keycloak completes the login -> the authorization code is exchanged for tokens, whose claims are printed.
const { chromium } = require('playwright');
const crypto = require('crypto');

const KC = 'http://localhost:8180/realms/authority';
const WALLET = 'http://localhost:7006';
const REDIRECT = 'http://localhost:9999/callback';
const walletId = process.argv[2];
const shots = process.argv[3] || '/tmp';

const b64u = (b) => b.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const claims = (jwt) => JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString());
const step = (n, msg) => console.log(`${n}) ${msg}`);

(async () => {
  const verifier = b64u(crypto.randomBytes(32));
  const challenge = b64u(crypto.createHash('sha256').update(verifier).digest());
  const authUrl = `${KC}/protocol/openid-connect/auth?client_id=lab-app&response_type=code&scope=openid`
    + `&redirect_uri=${encodeURIComponent(REDIRECT)}&state=lab&code_challenge=${challenge}&code_challenge_method=S256`;

  const browser = await chromium.launch();
  const page = await browser.newPage();
  let code = null;
  if (process.env.TRACE) {
    page.on('framenavigated', (f) => f === page.mainFrame() && console.log(`   [nav] ${f.url().slice(0, 160)}`));
    page.on('requestfailed', (r) => console.log(`   [failed] ${r.url().slice(0, 160)} ${r.failure()?.errorText}`));
  }
  // the final redirect to the app's callback carries the authorization code (route() does not see
  // redirect hops, so read it from the request itself; nothing needs to listen on :9999)
  page.on('request', (r) => {
    if (r.url().startsWith(REDIRECT)) code = new URL(r.url()).searchParams.get('code');
  });

  step(1, 'user opens the agent; redirected to its Keycloak login page');
  await page.goto(authUrl);
  await page.screenshot({ path: `${shots}/1-login.png` });

  step(2, 'user clicks "Verifiable Credentials" (OpenID4VP identity provider)');
  await page.click('#social-oid4vp');
  const uriBox = page.locator('pre.dynamic-uri-box');
  await uriBox.waitFor({ timeout: 30000 });
  await page.screenshot({ path: `${shots}/2-wallet-request.png` });
  const requestUrl = (await uriBox.textContent()).trim();
  console.log(`   page shows wallet request: ${requestUrl.slice(0, 110)}...`);

  step(3, 'user scans it with the wallet; wallet presents the credential (OpenID4VP)');
  const res = await fetch(`${WALLET}/wallet/${walletId}/credentials/present`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ requestUrl }),
  });
  console.log(`   wallet: ${JSON.stringify(await res.json())}`);

  step(4, 'page polling sees the verified presentation; Keycloak completes the brokered login');
  for (let i = 0; i < 40 && !code; i++) {
    if (await page.locator('#kc-idp-review-profile-form, form#kc-update-profile-form, input[name=username]').count()) {
      await page.screenshot({ path: `${shots}/4-first-login-profile.png` });
      console.log('   first login: Keycloak shows the review-profile form (prefilled from the credential); submitting');
      await page.click('input[type=submit], button[type=submit]');
    }
    await page.waitForTimeout(1000);
  }
  if (!code) {
    await page.screenshot({ path: `${shots}/fail.png` });
    console.log(`   no authorization code; page at ${page.url()}`);
    console.log((await page.content()).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').slice(0, 600));
    process.exit(1);
  }

  step(5, 'agent exchanges the authorization code for tokens');
  const tok = await (await fetch(`${KC}/protocol/openid-connect/token`, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'authorization_code', client_id: 'lab-app', code,
      redirect_uri: REDIRECT, code_verifier: verifier }),
  })).json();
  if (!tok.access_token) { console.log(tok); process.exit(1); }
  const id = claims(tok.id_token);
  const at = claims(tok.access_token);
  console.log(`   ID token: sub=${id.sub} preferred_username=${id.preferred_username}`);
  console.log(`             name="${id.given_name} ${id.family_name}" email=${id.email}`);
  console.log(`   access token: iss=${at.iss} azp=${at.azp} realm roles=${JSON.stringify((at.realm_access || {}).roles)}`);
  console.log('\nWALLET LOGIN OK');
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
