// ============================================================
// FILM FEATURES — stream each tagged game's film from R2 -> features
// ============================================================
//   node --env-file=.env ml/detect/extract-features.mjs [--all] [--jobs 2] [--video 1363]
//
// For every full-game film in ml/data/games.jsonl, ffmpeg reads the
// file straight from R2 over a signed link (hardware decode, 4 fps,
// 320x180) and pipes frames into ml/detect/featurize. Only the
// features are written, never the video: ~4 KB per second of film.
//
// Which parts of a film are read:
//   default  live play only (period_marks._cuts removed: warm-up,
//            intermissions), trimmed to 2 min before the first tagged
//            shot and 1 min after the last, so stretches nobody tagged
//            don't teach the model that shots there are "not shots".
//   --all    all live play (what a new, untagged game needs).
//
// Output: ml/data/features/<video>_<n>.{motion.f32,emb.f16,json}
// Re-running skips segments already done. Stops if disk gets low.

import fs from "fs";
import path from "path";
import { spawn, execFileSync } from "child_process";
import { fileURLToPath } from "url";
import { GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import ffmpegPath from "ffmpeg-static";
import { r2Configured, r2Client } from "../../api/_lib/supabase.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DATA = process.env.GOALIE_ML_DATA || path.join(HERE, "..", "data");  // override for tests
const OUT = path.join(DATA, "features");
const FEATURIZE = path.join(HERE, "featurize");

const FPS = 4;            // motion rate
const EMB_EVERY = 2;      // embedding every 2nd frame = 2 per second
const W = 320, H = 180;
const BEFORE_FIRST = 120, AFTER_LAST = 60, MIN_SEGMENT = 10;
const MIN_FREE_BYTES = 2 * 1024 * 1024 * 1024;

const argv = process.argv.slice(2);
const opt = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : null; };
const ALL = argv.includes("--all");
const JOBS = Number(opt("--jobs") || 2);
const ONLY = opt("--video");
const GAMES_FILE = opt("--games") || path.join(DATA, "games.jsonl");

// Local files (absolute paths) are read directly: used by the tests.
const isLocal = p => path.isAbsolute(p) && fs.existsSync(p);
if (!r2Configured() && !process.env.GOALIE_ML_DATA) {
  console.error("Needs R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET_NAME in .env");
  process.exit(1);
}
if (!fs.existsSync(FEATURIZE)) {
  console.error("Build the featurizer first: swiftc -O ml/detect/featurize.swift -o ml/detect/featurize");
  process.exit(1);
}
fs.mkdirSync(OUT, { recursive: true });

// ---- which seconds of each film to read ----

function liveSegments(film) {
  const dur = film.duration_seconds;
  if (!dur) return [];
  const cuts = (Array.isArray(film.period_marks?._cuts) ? film.period_marks._cuts : [])
    .map(([a, b]) => [Math.max(0, +a), Math.min(dur, +b)])
    .filter(([a, b]) => b > a)
    .sort((x, y) => x[0] - y[0]);
  let segs = [];
  let at = 0;
  for (const [a, b] of cuts) {
    if (a > at) segs.push([at, a]);
    at = Math.max(at, b);
  }
  if (at < dur) segs.push([at, dur]);

  if (!ALL && film.shot_times.length) {
    const lo = Math.max(0, film.shot_times[0] - BEFORE_FIRST);
    const hi = Math.min(dur, film.shot_times[film.shot_times.length - 1] + AFTER_LAST);
    segs = segs.map(([a, b]) => [Math.max(a, lo), Math.min(b, hi)]).filter(([a, b]) => b > a);
  }
  return segs.filter(([a, b]) => b - a >= MIN_SEGMENT).map(([a, b]) => [Math.round(a * 100) / 100, Math.round(b * 100) / 100]);
}

// ---- run one segment: ffmpeg (R2) | featurize ----

function runSegment(url, start, end, prefix) {
  return new Promise((resolve, reject) => {
    const ff = spawn(ffmpegPath, [
      "-hide_banner", "-loglevel", "error",
      "-hwaccel", "videotoolbox",
      ...(url.startsWith("http") ? ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "10"] : []),
      "-ss", String(start), "-i", url, "-t", String(end - start),
      "-an", "-vf", `fps=${FPS},scale=${W}:${H}`, "-pix_fmt", "bgra", "-f", "rawvideo", "-",
    ]);
    const fz = spawn(FEATURIZE, [String(W), String(H), String(EMB_EVERY), prefix]);
    ff.stdout.pipe(fz.stdin);
    let ffErr = "", fzOut = "", fzErr = "";
    ff.stderr.on("data", d => (ffErr += d));
    fz.stdout.on("data", d => (fzOut += d));
    fz.stderr.on("data", d => (fzErr += d));
    let ffCode = null;
    ff.on("close", c => (ffCode = c));
    ff.on("error", reject);
    fz.on("error", reject);
    fz.on("close", code => {
      if (code !== 0) return reject(new Error(`featurize exit ${code}: ${fzErr.trim().slice(-300)}`));
      if (ffCode && ffCode !== 0) return reject(new Error(`ffmpeg exit ${ffCode}: ${ffErr.trim().slice(-300)}`));
      try { resolve(JSON.parse(fzOut.trim().split("\n").pop())); }
      catch { reject(new Error(`featurize output: ${fzOut.slice(-200)}`)); }
    });
  });
}

function freeBytes() {
  try {
    const line = execFileSync("df", ["-k", DATA]).toString().trim().split("\n").pop();
    return Number(line.split(/\s+/)[3]) * 1024;
  } catch { return Infinity; }
}

// ---- main ----

const games = fs.readFileSync(GAMES_FILE, "utf8").trim().split("\n").map(l => JSON.parse(l));
const jobs = [];
for (const g of games) {
  for (const film of g.film || []) {
    if (ONLY && String(film.video_id) !== String(ONLY)) continue;
    liveSegments(film).forEach(([start, end], n) => {
      jobs.push({ game_id: g.game_id, user_id: g.user_id, film, start, end, n });
    });
  }
}
const totalSeconds = jobs.reduce((s, j) => s + (j.end - j.start), 0);
console.log(`${jobs.length} segments, ${(totalSeconds / 3600).toFixed(1)} h of film to read (${ALL ? "all live play" : "tagged span only"})`);

const s3 = r2Configured() ? r2Client() : null;
const urls = new Map();
async function signed(key) {
  if (isLocal(key)) return key;
  if (!urls.has(key)) {
    urls.set(key, await getSignedUrl(s3, new GetObjectCommand({ Bucket: process.env.R2_BUCKET_NAME, Key: key }), { expiresIn: 12 * 3600 }));
  }
  return urls.get(key);
}

let next = 0, doneSeconds = 0, failed = 0, stopped = false;
const t0 = Date.now();

async function worker() {
  while (next < jobs.length && !stopped) {
    const j = jobs[next++];
    const prefix = path.join(OUT, `${j.film.video_id}_${j.n}`);
    const metaFile = prefix + ".json";
    if (fs.existsSync(metaFile)) { doneSeconds += j.end - j.start; continue; }
    // macOS grows and shrinks swap on its own, so free space dips and
    // recovers. Wait out a dip; stop only if it stays low for 10 minutes.
    if (freeBytes() < MIN_FREE_BYTES) {
      const gb = () => (freeBytes() / 1e9).toFixed(1);
      console.error(`Disk low (${gb()} GB free). Pausing until it's back above 2 GB…`);
      const giveUp = Date.now() + 10 * 60 * 1000;
      while (freeBytes() < MIN_FREE_BYTES && Date.now() < giveUp && !stopped) {
        await new Promise(r => setTimeout(r, 30000));
      }
      if (stopped) return;
      if (freeBytes() < MIN_FREE_BYTES) {
        console.error(`\nStopping: disk stayed under 2 GB free for 10 minutes (${gb()} GB now). Free some space and re-run; finished segments are kept.`);
        stopped = true;
        return;
      }
      console.error(`Disk back to ${gb()} GB free. Continuing.`);
    }
    const began = Date.now();
    try {
      const out = await runSegment(await signed(j.film.storage_path), j.start, j.end, prefix);
      const expected = Math.floor((j.end - j.start) * FPS);
      if (out.frames < expected * 0.9) throw new Error(`only ${out.frames} of ~${expected} frames decoded`);
      fs.writeFileSync(metaFile, JSON.stringify({
        video_id: j.film.video_id, game_id: j.game_id, user_id: j.user_id, segment: j.n,
        start: j.start, end: j.end, fps: FPS, emb_every: EMB_EVERY, width: W, height: H, ...out,
      }));
      doneSeconds += j.end - j.start;
      const rate = (j.end - j.start) / ((Date.now() - began) / 1000);
      const elapsed = (Date.now() - t0) / 1000;
      const eta = doneSeconds > 0 ? ((totalSeconds - doneSeconds) / (doneSeconds / elapsed)) / 60 : 0;
      console.log(`video ${j.film.video_id} part ${j.n}: ${((j.end - j.start) / 60).toFixed(0)} min of film at ${rate.toFixed(0)}x realtime | ${(100 * doneSeconds / totalSeconds).toFixed(0)}% done, ~${eta.toFixed(0)} min left`);
    } catch (e) {
      failed++;
      for (const ext of [".motion.f32", ".emb.f16"]) fs.rmSync(prefix + ext, { force: true });
      console.error(`video ${j.film.video_id} part ${j.n} failed: ${e.message}`);
    }
  }
}

await Promise.all(Array.from({ length: JOBS }, worker));
console.log(`Finished: ${(doneSeconds / 3600).toFixed(1)} of ${(totalSeconds / 3600).toFixed(1)} h, ${failed} segment(s) failed${stopped ? ", stopped for disk space" : ""}.`);
process.exit(failed || stopped ? 1 : 0);
