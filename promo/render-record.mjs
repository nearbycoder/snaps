// Renders record.html to ../docs/assets/record.jpg (the site's recording illustration, at 2×).
import { chromium } from "playwright-core";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const browser = await chromium.launch({ channel: "chrome", headless: true, args: ["--force-color-profile=srgb"] });
const page = await browser.newPage({ viewport: { width: 1200, height: 700 }, deviceScaleFactor: 2 });
await page.goto(pathToFileURL(join(here, "record.html")).href);
await page.evaluate(() => document.fonts.ready);
const out = join(here, "..", "docs", "assets", "record.jpg");
await page.screenshot({ path: out, type: "jpeg", quality: 88 });
await browser.close();
console.log(`✓ ${out}`);
