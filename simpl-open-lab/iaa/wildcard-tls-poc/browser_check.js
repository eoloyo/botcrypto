// browser_check.js <ip:port> <ca-pem-unused> <hosts-ok-file> <hosts-bad-file> — real Chromium, normal certificate verification.
// proxy.bypass='*' makes Chromium go direct (the sandbox's egress proxy would otherwise answer; --no-proxy-server is ignored).
// The lab CA is in the browser's NSS trust store (browser_test.sh), so chain AND hostname are verified exactly as for a user.
const { chromium } = require('playwright');
const fs = require('fs');
const [target, , okFile, badFile] = process.argv.slice(2);
const hosts = f => fs.readFileSync(f, 'utf8').split('\n').map(l => l.replace(/#.*/, '').trim()).filter(Boolean);
(async () => {
  const browser = await chromium.launch({ proxy: { server: 'http://127.0.0.1:9', bypass: '*' }, args: [`--host-resolver-rules=MAP *.dataspace.example.eu ${target}, MAP dataspace.example.eu ${target}`] });
  const results = [];
  for (const h of hosts(okFile)) {
    const page = await browser.newPage();
    try {
      const r = await page.goto(`https://${h}/`, { timeout: 30000 });
      const sd = await r.securityDetails();
      results.push({ host: h, kind: 'ok', status: r.status(), title: await page.title(), issuer: sd && sd.issuer, protocol: sd && sd.protocol });
    } catch (e) { results.push({ host: h, kind: 'ok', error: String(e.message).split('\n')[0] }); }
    await page.close();
  }
  for (const h of hosts(badFile)) {
    const page = await browser.newPage();
    try { const r = await page.goto(`https://${h}/`, { timeout: 30000 }); results.push({ host: h, kind: 'bad', status: r.status(), error: null }); }
    catch (e) { results.push({ host: h, kind: 'bad', error: (String(e.message).match(/net::ERR_[A-Z_]+/) || [String(e.message).split('\n')[0]])[0] }); }
    await page.close();
  }
  await browser.close();
  console.log(JSON.stringify(results));
})();
