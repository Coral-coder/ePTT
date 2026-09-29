// Renders the App Store screenshots: node render.mjs (from this folder).
import { createRequire } from 'module';
import { execSync } from 'child_process';
import path from 'path';
import fs from 'fs';
const require = createRequire(import.meta.url);
const { chromium } = require(path.join(execSync('npm root -g').toString().trim(), 'playwright'));

const here = path.dirname(new URL(import.meta.url).pathname);
const out = path.join(here, '..');
const qr = 'data:image/svg+xml;base64,' + fs.readFileSync(path.join(here, 'qr.svg')).toString('base64');
const jobs = [
  // iPhone 6.9" (1320 × 2868)
  ...['talk', 'rx', 'tx', 'channels', 'invite', 'face'].map((s, i) => ({ device: 'iphone', screen: s, w: 440, h: 956, scale: 3, file: `iphone-6.9/${i + 1}-${s}.png` })),
  // iPad 13" (2064 × 2752)
  ...['talk', 'rx', 'channels', 'invite', 'face'].map((s, i) => ({ device: 'ipad', screen: s, w: 1032, h: 1376, scale: 2, file: `ipad-13/${i + 1}-${s}.png` })),
  // Apple Watch 46 mm (416 × 496)
  ...['watch-idle', 'watch-rx'].map((s, i) => ({ device: 'watch', screen: s, w: 208, h: 248, scale: 2, file: `watch/${i + 1}-${s.replace('watch-', '')}.png` })),
];
const only = process.argv[2];
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' }).catch(() => chromium.launch());
for (const job of jobs.filter(j => !only || j.file.includes(only))) {
  const page = await browser.newPage({ viewport: { width: job.w, height: job.h }, deviceScaleFactor: job.scale });
  const url = `file://${path.join(here, 'screens.html')}?device=${job.device}&screen=${job.screen}&qr=${encodeURIComponent(qr)}`;
  await page.goto(url);
  await page.waitForSelector('body[data-ready="1"]');
  await page.waitForTimeout(150);
  const file = path.join(out, job.file);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  await page.screenshot({ path: file, clip: { x: 0, y: 0, width: job.w, height: job.h } });
  console.log(job.file);
  await page.close();
}
await browser.close();
