// Synthesizes the promo soundtrack (music bed + UI sound effects) to promo/build/promo-audio.wav.
// Everything is generated procedurally, so there are no third-party samples or licensing to track.
// Effect timestamps match the timeline in promo.html (absolute seconds).
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const SR = 48000;
const DURATION = 49.5;
const N = SR * DURATION;

const music = [new Float32Array(N), new Float32Array(N)];
const sfx = [new Float32Array(N), new Float32Array(N)];
const send = [new Float32Array(N), new Float32Array(N)]; // reverb send

// ---------- helpers ----------
let seed = 1234567;
const rand = () => ((seed = (seed * 1103515245 + 12345) >>> 0) / 4294967296) * 2 - 1;
const mtof = (m) => 440 * Math.pow(2, (m - 69) / 12);
const db = (d) => Math.pow(10, d / 20);

function add(bus, t, buf, gain = 1, pan = 0, rev = 0) {
  const start = Math.round(t * SR);
  const l = Math.cos((pan + 1) * Math.PI / 4) * gain, r = Math.sin((pan + 1) * Math.PI / 4) * gain;
  for (let i = 0; i < buf.length; i++) {
    const j = start + i;
    if (j < 0 || j >= N) continue;
    bus[0][j] += buf[i] * l; bus[1][j] += buf[i] * r;
    if (rev) { send[0][j] += buf[i] * l * rev; send[1][j] += buf[i] * r * rev; }
  }
}

// RBJ biquad
function biquad(type, f, q = 0.707) {
  const w = 2 * Math.PI * f / SR, c = Math.cos(w), s = Math.sin(w), a = s / (2 * q);
  let b0, b1, b2, a0, a1, a2;
  if (type === "lp") { b0 = (1 - c) / 2; b1 = 1 - c; b2 = (1 - c) / 2; }
  else if (type === "hp") { b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2; }
  else { b0 = a; b1 = 0; b2 = -a; } // band-pass
  a0 = 1 + a; a1 = -2 * c; a2 = 1 - a;
  return { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0, x1: 0, x2: 0, y1: 0, y2: 0 };
}
function run(fl, x) {
  const y = fl.b0 * x + fl.b1 * fl.x1 + fl.b2 * fl.x2 - fl.a1 * fl.y1 - fl.a2 * fl.y2;
  fl.x2 = fl.x1; fl.x1 = x; fl.y2 = fl.y1; fl.y1 = y;
  return y;
}
const env = (i, len, a, r) => { const t = i / SR, d = len / SR; return Math.min(1, t / a) * Math.min(1, Math.max(0, (d - t) / r)); };

// ---------- instruments ----------
function pad(freqs, dur) {
  const len = Math.round(dur * SR), out = new Float32Array(len);
  const lp = biquad("lp", 1800, 0.6);
  const voices = freqs.flatMap((f) => [f * 0.997, f, f * 1.004]);
  const ph = voices.map(() => (rand() + 1) * 3.14);
  for (let i = 0; i < len; i++) {
    let v = 0;
    for (let k = 0; k < voices.length; k++) {
      ph[k] += 2 * Math.PI * voices[k] / SR;
      const p = ph[k];
      v += Math.sin(p) + 0.32 * Math.sin(2 * p) + 0.14 * Math.sin(3 * p) + 0.06 * Math.sin(4 * p);
    }
    out[i] = run(lp, v / voices.length) * env(i, len, 0.5, 0.9);
  }
  return out;
}
function bell(f, dur = 1.2, bright = 2.2) {
  const len = Math.round(dur * SR), out = new Float32Array(len);
  for (let i = 0; i < len; i++) {
    const t = i / SR, e = Math.exp(-t * 4.2);
    const mod = Math.sin(2 * Math.PI * f * 3.5 * t) * bright * Math.exp(-t * 9);
    out[i] = Math.sin(2 * Math.PI * f * t + mod) * e * Math.min(1, t / 0.004);
  }
  return out;
}
function pluck(f, dur = 0.5) {
  const len = Math.round(dur * SR), out = new Float32Array(len);
  for (let i = 0; i < len; i++) {
    const t = i / SR, e = Math.exp(-t * 7);
    out[i] = (Math.sin(2 * Math.PI * f * t) + 0.4 * Math.sin(4 * Math.PI * f * t) * Math.exp(-t * 14)) * e * Math.min(1, t / 0.003);
  }
  return out;
}
function bass(f, dur) {
  const len = Math.round(dur * SR), out = new Float32Array(len);
  for (let i = 0; i < len; i++) {
    const t = i / SR;
    const v = Math.sin(2 * Math.PI * f * t) + 0.25 * Math.sin(4 * Math.PI * f * t);
    out[i] = Math.tanh(v * 1.4) * env(i, len, 0.01, 0.08);
  }
  return out;
}
function kick() {
  const len = Math.round(0.35 * SR), out = new Float32Array(len);
  let ph = 0;
  for (let i = 0; i < len; i++) {
    const t = i / SR, f = 45 + 95 * Math.exp(-t * 28);
    ph += 2 * Math.PI * f / SR;
    out[i] = Math.sin(ph) * Math.exp(-t * 9) + rand() * 0.05 * Math.exp(-t * 200);
  }
  return out;
}
function noiseHit(dur, type, f, q, decay) {
  const len = Math.round(dur * SR), out = new Float32Array(len), fl = biquad(type, f, q);
  for (let i = 0; i < len; i++) out[i] = run(fl, rand()) * Math.exp(-(i / SR) * decay);
  return out;
}
const clap = () => noiseHit(0.22, "bp", 1500, 0.9, 22);
const hat = () => noiseHit(0.06, "hp", 8000, 0.7, 70);

// ---------- sound effects ----------
const keyClick = () => {
  const a = noiseHit(0.03, "bp", 3200, 1.4, 220), out = new Float32Array(a.length);
  for (let i = 0; i < a.length; i++) out[i] = a[i] * 1.6 + Math.sin(2 * Math.PI * 1900 * i / SR) * Math.exp(-(i / SR) * 160) * 0.35;
  return out;
};
function shutter() {
  const len = Math.round(0.28 * SR), out = new Float32Array(len);
  const c1 = noiseHit(0.05, "bp", 2400, 1.1, 90), c2 = noiseHit(0.08, "bp", 1700, 1.0, 60);
  const off = Math.round(0.075 * SR);
  for (let i = 0; i < c1.length; i++) out[i] += c1[i] * 1.6;
  for (let i = 0; i < c2.length && i + off < len; i++) out[i + off] += c2[i] * 1.4;
  for (let i = 0; i < len; i++) out[i] += Math.sin(2 * Math.PI * 140 * i / SR) * Math.exp(-(i / SR) * 30) * 0.4;
  return out;
}
function whoosh(dur = 0.45, f0 = 500, f1 = 2600) {
  const len = Math.round(dur * SR), out = new Float32Array(len);
  let fl = biquad("bp", f0, 0.8);
  for (let i = 0; i < len; i++) {
    const k = i / len;
    if (i % 32 === 0) { const n = biquad("bp", f0 + (f1 - f0) * k, 0.8); Object.assign(fl, { b0: n.b0, b1: n.b1, b2: n.b2, a1: n.a1, a2: n.a2 }); }
    out[i] = run(fl, rand()) * Math.sin(Math.PI * k) ** 1.5 * 1.8;
  }
  return out;
}
function pop(f0 = 520, f1 = 980, dur = 0.12) {
  const len = Math.round(dur * SR), out = new Float32Array(len);
  let ph = 0;
  for (let i = 0; i < len; i++) {
    const t = i / SR, f = f1 + (f0 - f1) * Math.exp(-t * 60);
    ph += 2 * Math.PI * f / SR;
    out[i] = Math.sin(ph) * Math.exp(-t * 32) * Math.min(1, t / 0.002);
  }
  return out;
}
function thunk() {
  const len = Math.round(0.2 * SR), out = new Float32Array(len);
  let ph = 0;
  for (let i = 0; i < len; i++) {
    const t = i / SR, f = 170 + 160 * Math.exp(-t * 40);
    ph += 2 * Math.PI * f / SR;
    out[i] = Math.sin(ph) * Math.exp(-t * 22);
  }
  const n = noiseHit(0.04, "lp", 1200, 0.7, 90);
  for (let i = 0; i < n.length; i++) out[i] += n[i] * 0.5;
  return out;
}
function chime(notes, gap = 0.09) {
  const parts = notes.map((m) => bell(mtof(m), 1.4, 1.2));
  const len = Math.round(gap * SR) * (notes.length - 1) + parts[0].length, out = new Float32Array(len);
  parts.forEach((p, k) => { const off = Math.round(gap * SR) * k; for (let i = 0; i < p.length; i++) out[off + i] += p[i]; });
  return out;
}
function riser(dur = 1.4) {
  const len = Math.round(dur * SR), out = new Float32Array(len);
  let fl = biquad("bp", 300, 1.2);
  for (let i = 0; i < len; i++) {
    const k = i / len;
    if (i % 32 === 0) { const n = biquad("bp", 300 + 5000 * k * k, 1.2); Object.assign(fl, { b0: n.b0, b1: n.b1, b2: n.b2, a1: n.a1, a2: n.a2 }); }
    out[i] = run(fl, rand()) * k ** 2 * 1.6;
  }
  return out;
}

// ---------- music ----------
const BPM = 104, BEAT = 60 / BPM, BAR = BEAT * 4;
// Fmaj7 – G6 – Em7 – Am7 (C major), voiced around middle C.
const CHORDS = [
  { root: 41, notes: [53, 57, 60, 64] },
  { root: 43, notes: [55, 59, 62, 64] },
  { root: 40, notes: [52, 55, 59, 62] },
  { root: 45, notes: [57, 60, 64, 67] },
];
const OUTRO = 45.4; // outro starts (absolute)
const bars = Math.ceil(DURATION / BAR);
for (let b = 0; b < bars; b++) {
  const t0 = b * BAR, ch = CHORDS[b % 4];
  if (t0 >= OUTRO) break;
  add(music, t0, pad(ch.notes.map(mtof), BAR + 0.9), db(-15), 0, 0.35);

  const groove = t0 >= 3.6;          // drums + bass after the intro
  const full = t0 >= 12.0;           // hats + claps once the demo starts
  for (let beat = 0; beat < 4; beat++) {
    const tb = t0 + beat * BEAT;
    if (tb >= OUTRO - 0.05) break;
    if (groove) {
      if (beat === 0 || beat === 2) add(music, tb, kick(), db(-9));
      add(music, tb, bass(mtof(ch.root - 12 + (beat === 3 ? 7 : 0)), BEAT * 0.9), db(-15));
      add(music, tb + BEAT / 2, bass(mtof(ch.root - 12), BEAT * 0.4), db(-19));
    }
    if (full) {
      if (beat === 1 || beat === 3) add(music, tb, clap(), db(-19), 0, 0.25);
      add(music, tb, hat(), db(-27), 0.3);
      add(music, tb + BEAT / 2, hat(), db(-23), -0.3);
    }
    // Arpeggiated plucks from the chord, alternating sides.
    if (t0 >= 1.8) {
      for (let s = 0; s < 2; s++) {
        const n = ch.notes[(beat * 2 + s + b) % 4] + 12;
        add(music, tb + s * BEAT / 2, pluck(mtof(n), 0.45), db(full ? -21 : -23), s ? 0.45 : -0.45, 0.3);
      }
    }
  }
}
// Outro: final chord + sparkle.
add(music, OUTRO - 1.4, riser(1.4), db(-20), 0, 0.3);
add(music, OUTRO, pad([53, 57, 60, 64, 69].map(mtof), 4.3), db(-12), 0, 0.5);
add(music, OUTRO, kick(), db(-8));
add(music, OUTRO, (() => {
  const len = Math.round(3.2 * SR), out = new Float32Array(len);
  for (let i = 0; i < len; i++) { const t = i / SR; out[i] = Math.sin(2 * Math.PI * mtof(41) * t) * Math.exp(-t * 1.6) * Math.min(1, t / 0.01); }
  return out;
})(), db(-14));
[[OUTRO + 0.0, 77], [OUTRO + 0.18, 81], [OUTRO + 0.36, 84], [OUTRO + 0.54, 88]].forEach(([t, m], k) =>
  add(music, t, bell(mtof(m), 2.2, 1.4), db(-20), k % 2 ? 0.3 : -0.3, 0.6));

// ---------- effects (absolute times) ----------
// Main-timeline seconds → absolute seconds (the install scene inserts 8s at 4.0, the editor scene 7.5s at 20.7).
const M = (m) => (m < 4 ? m : m < 20.7 ? m + 8 : m + 15.5);
const E0 = 28.7; // editor scene start (absolute)
const fx = [];
const at = (t, buf, gain, pan = 0, rev = 0.15) => fx.push([t, buf, gain, pan, rev]);

// Intro
at(0.12, chime([76, 83, 88], 0.08), db(-16), 0, 0.5);
at(1.55, pop(600, 1100), db(-20));
// Install scene
at(3.3, whoosh(0.5, 400, 1800), db(-22));
at(4.85, pop(900, 1300, 0.06), db(-20));
at(4.9, whoosh(0.9, 700, 1500), db(-28));
at(5.95, thunk(), db(-15));
at(6.45, whoosh(0.55, 500, 2200), db(-22));
at(6.95, whoosh(0.4, 900, 2600), db(-26));
at(8.05, pop(900, 1300, 0.06), db(-20));
at(9.05, thunk(), db(-16));
at(9.8, keyClick(), db(-12));
at(9.9, chime([84, 91], 0.1), db(-16), 0, 0.4);
// Area capture
for (const k of [4.95, 5.1, 5.25]) at(M(k), keyClick(), db(-10), -0.1);
at(M(6.35), pop(700, 1000, 0.05), db(-24));
at(M(7.66), shutter(), db(-8));
at(M(7.95), whoosh(0.5, 600, 2400), db(-21), -0.5);
// Paste + send
at(M(9.9), keyClick(), db(-14), 0.4);
for (const k of [10.4, 10.55]) at(M(k), keyClick(), db(-10), 0.1);
at(M(10.75), pop(), db(-17), 0.4);
at(M(11.35), whoosh(0.35, 1200, 3200), db(-21), 0.5);
at(M(11.4), pop(800, 1400, 0.08), db(-22), 0.5);
// Window capture
at(M(12.95), whoosh(0.4, 500, 1600), db(-25));
for (const k of [14.05, 14.2, 14.35]) at(M(k), keyClick(), db(-10), -0.1);
at(M(16.0), shutter(), db(-8));
at(M(16.25), whoosh(0.5, 600, 2400), db(-21), -0.5);
// Drag & drop
at(M(17.72), pop(900, 1300, 0.06), db(-20), -0.4);
at(M(17.8), whoosh(1.1, 700, 1500), db(-29));
at(M(18.95), thunk(), db(-15), 0.4);
at(M(20.2), chime([81, 88], 0.07), db(-18), 0.5, 0.3);
// Annotation editor scene
at(E0 + 0.8, keyClick(), db(-13), -0.6);
at(E0 + 0.95, keyClick(), db(-13), -0.6);
at(E0 + 1.0, whoosh(0.45, 500, 2000), db(-21));
at(E0 + 1.5, keyClick(), db(-10));
at(E0 + 1.75, whoosh(1.2, 900, 1700), db(-30), 0.2);
at(E0 + 2.95, pop(700, 1000, 0.05), db(-24), 0.3);
at(E0 + 3.1, keyClick(), db(-10));
at(E0 + 3.55, keyClick(), db(-15), 0.1);
for (let i = 0; i < 14; i++) at(E0 + 3.6 + i * 0.06, keyClick(), db(-21 - (i % 3)), 0.1 + (i % 2) * 0.05);
at(E0 + 4.6, keyClick(), db(-10));
at(E0 + 5.05, whoosh(0.65, 400, 900), db(-26), -0.3);
at(E0 + 6.45, keyClick(), db(-12), 0.5);
at(E0 + 6.5, chime([84, 88, 91], 0.07), db(-17), 0.3, 0.35);
at(E0 + 6.55, whoosh(0.35, 1800, 700), db(-24));
at(E0 + 6.7, pop(), db(-18), -0.6);
// Corner picker
at(M(20.85), keyClick(), db(-13), 0.6);
at(M(20.9), whoosh(0.3, 1200, 3000), db(-25), 0.6);
at(M(22.15), keyClick(), db(-12), 0.6);
at(M(22.6), whoosh(0.5, 500, 2200), db(-21), 0.6);
// Gallery
for (const k of [25.05, 25.2, 25.35]) at(M(k), keyClick(), db(-10));
at(M(25.5), whoosh(0.6, 300, 1800), db(-19));
for (let i = 0; i < 6; i++) at(M(25.78 + i * 0.07), pop(700 + i * 60, 1100 + i * 80, 0.05), db(-27), -0.6 + i * 0.24);
at(M(28.15), keyClick(), db(-12));
at(M(28.2), pop(), db(-18));
at(M(29.3), whoosh(0.4, 1800, 600), db(-24));

for (const [t, buf, gain, pan, rev] of fx) add(sfx, t, buf, gain, pan, rev);

// ---------- mix ----------
// Duck the music under effects a little.
const duck = new Float32Array(N);
for (const [t, buf] of fx) {
  const s0 = Math.round(t * SR), len = Math.min(buf.length, Math.round(0.25 * SR));
  for (let i = -Math.round(0.02 * SR); i < len + Math.round(0.15 * SR); i++) {
    const j = s0 + i;
    if (j >= 0 && j < N) duck[j] = Math.max(duck[j], 0.25);
  }
}

// Simple stereo reverb (Freeverb-style combs + allpasses).
function reverb(input, offset) {
  const out = new Float32Array(N);
  const combs = [1557, 1617, 1491, 1422].map((d) => ({ buf: new Float32Array(d + offset), i: 0, lp: 0 }));
  const aps = [556, 441].map((d) => ({ buf: new Float32Array(d + offset), i: 0 }));
  for (let n = 0; n < N; n++) {
    const x = input[n] * 0.12;
    let y = 0;
    for (const c of combs) {
      const o = c.buf[c.i];
      c.lp = o * 0.7 + c.lp * 0.3;
      c.buf[c.i] = x + c.lp * 0.84;
      c.i = (c.i + 1) % c.buf.length;
      y += o;
    }
    for (const a of aps) {
      const o = a.buf[a.i];
      a.buf[a.i] = y + o * 0.5;
      a.i = (a.i + 1) % a.buf.length;
      y = o - y * 0.5;
    }
    out[n] = y;
  }
  return out;
}
const wet = [reverb(send[0], 0), reverb(send[1], 23)];

const pcm = Buffer.alloc(N * 4);
let peak = 0;
const mix = [new Float32Array(N), new Float32Array(N)];
let d = 0;
for (let n = 0; n < N; n++) {
  d = Math.max(duck[n], d * 0.9995);
  const t = n / SR;
  const fade = Math.min(1, t / 1.2) * Math.min(1, (DURATION - t) / 1.8);
  for (let c = 0; c < 2; c++) {
    const v = (music[c][n] * (1 - d) + sfx[c][n] + wet[c][n] * 0.9) * fade;
    mix[c][n] = v;
    peak = Math.max(peak, Math.abs(v));
  }
}
const norm = 0.89 / Math.max(peak, 1e-6);
for (let n = 0; n < N; n++) {
  for (let c = 0; c < 2; c++) {
    const v = Math.tanh(mix[c][n] * norm * 1.1) / Math.tanh(1.1);
    pcm.writeInt16LE(Math.round(Math.max(-1, Math.min(1, v)) * 32767), (n * 2 + c) * 2);
  }
}

const header = Buffer.alloc(44);
header.write("RIFF", 0); header.writeUInt32LE(36 + pcm.length, 4); header.write("WAVE", 8);
header.write("fmt ", 12); header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(2, 22);
header.writeUInt32LE(SR, 24); header.writeUInt32LE(SR * 4, 28); header.writeUInt16LE(4, 32); header.writeUInt16LE(16, 34);
header.write("data", 36); header.writeUInt32LE(pcm.length, 40);

const outDir = join(here, "build");
mkdirSync(outDir, { recursive: true });
const out = join(outDir, "promo-audio.wav");
writeFileSync(out, Buffer.concat([header, pcm]));
console.log(`✓ ${out} (${DURATION}s, peak normalized)`);
