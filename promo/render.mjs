// Renders promo.html to an MP4 by stepping its timeline frame by frame.
//   node render.mjs                     → ../docs/assets/promo.mp4 + poster
//   node render.mjs --stills 2,8.5,…    → PNG stills in ./stills for review
import { chromium } from "playwright-core";
import { spawn } from "node:child_process";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const FPS = 60;
const W = 1920, H = 1080;
const outDir = join(here, "..", "docs", "assets");
const stillsArg = process.argv.indexOf("--stills");

const browser = await chromium.launch({
  channel: "chrome",
  headless: true,
  args: ["--force-color-profile=srgb", "--hide-scrollbars", "--font-render-hinting=none"],
});
const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
await page.goto(pathToFileURL(join(here, "promo.html")).href + "?render=1");
await page.waitForFunction(() => window.__ready === true);
await page.evaluate(() => document.fonts.ready);
const duration = await page.evaluate(() => window.DURATION);

const frameAt = async (t, type = "jpeg") => {
  await page.evaluate((time) => window.renderAt(time), t);
  return page.screenshot(type === "png" ? { type: "png" } : { type: "jpeg", quality: 96 });
};

if (stillsArg !== -1) {
  const dir = join(here, "stills");
  mkdirSync(dir, { recursive: true });
  for (const t of process.argv[stillsArg + 1].split(",").map(Number)) {
    const buf = await frameAt(t, "png");
    const { writeFileSync } = await import("node:fs");
    writeFileSync(join(dir, `t${t.toFixed(2)}.png`), buf);
    console.log(`still t=${t}`);
  }
  await browser.close();
  process.exit(0);
}

mkdirSync(outDir, { recursive: true });
const output = join(here, "build", "promo-video.mp4");
mkdirSync(join(here, "build"), { recursive: true });
const ffmpeg = spawn("ffmpeg", [
  "-y", "-loglevel", "error",
  "-f", "image2pipe", "-framerate", String(FPS), "-i", "-",
  "-c:v", "libx264", "-preset", "slow", "-crf", "21", "-pix_fmt", "yuv420p",
  "-movflags", "+faststart", output,
], { stdio: ["pipe", "inherit", "inherit"] });

const total = Math.round(duration * FPS);
const started = Date.now();
for (let i = 0; i < total; i++) {
  const buf = await frameAt(i / FPS);
  if (!ffmpeg.stdin.write(buf)) await new Promise((r) => ffmpeg.stdin.once("drain", r));
  if (i % 120 === 0) console.log(`frame ${i}/${total} (${((Date.now() - started) / 1000).toFixed(0)}s)`);
}
ffmpeg.stdin.end();
await new Promise((r) => ffmpeg.on("close", r));

// Poster frame for the web page.
const poster = await frameAt(46.9);
const { writeFileSync } = await import("node:fs");
writeFileSync(join(outDir, "promo-poster.jpg"), poster);

await browser.close();

// Mux in the synthesized soundtrack (npm run audio), loudness-normalized for the web.
const audio = join(here, "build", "promo-audio.wav");
const final = join(outDir, "promo.mp4");
await new Promise((resolve, reject) => {
  const mux = spawn("ffmpeg", [
    "-y", "-loglevel", "error", "-i", output, "-i", audio,
    "-map", "0:v", "-map", "1:a", "-c:v", "copy",
    "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-c:a", "aac", "-b:a", "160k", "-ar", "48000",
    "-shortest", "-movflags", "+faststart", final,
  ], { stdio: "inherit" });
  mux.on("close", (code) => (code === 0 ? resolve() : reject(new Error(`ffmpeg exited ${code}`))));
});
console.log(`✓ ${final}`);

// Cache-bust the site's references so browsers fetch the new video/poster.
const { createHash } = await import("node:crypto");
const { readFileSync } = await import("node:fs");
const indexPath = join(here, "..", "docs", "index.html");
const hash = (f) => createHash("sha256").update(readFileSync(f)).digest("hex").slice(0, 10);
const html = readFileSync(indexPath, "utf8")
  .replace(/assets\/promo\.mp4(\?v=[\w]+)?/g, `assets/promo.mp4?v=${hash(final)}`)
  .replace(/assets\/promo-poster\.jpg(\?v=[\w]+)?/g, `assets/promo-poster.jpg?v=${hash(join(outDir, "promo-poster.jpg"))}`);
writeFileSync(indexPath, html);
console.log("✓ docs/index.html cache-busted");
