// ============================================================
// Still frames from a stored game video, extracted on the server
// ============================================================
// ffmpeg reads the video straight from R2 over a short-lived signed
// URL, seeking with HTTP range requests, so only the bytes around each
// timestamp are fetched. Server-to-R2 traffic isn't subject to browser
// CORS rules (and R2 doesn't charge egress), which is why the AI review
// works without any bucket CORS setup.

import { spawn } from "child_process";
import fs from "fs";
import ffmpegPath from "ffmpeg-static";

export function ffmpegAvailable() {
  try {
    return !!ffmpegPath && fs.existsSync(ffmpegPath);
  } catch (e) {
    return false;
  }
}

// Size of the grey thumbnail used to tell whether anything moved.
const THUMB_W = 96;
const THUMB_H = 54;

// One JPEG at `t` seconds, scaled to `width` pixels wide, as base64.
// With `thumb`, the same decoded frame also comes back as a tiny grey
// thumbnail (raw bytes) for the dead-time check below; ffmpeg writes it
// to a second pipe so the video is only read once.
export function grabFrame(url, t, width, timeoutMs = 25000, thumb = false) {
  return new Promise((resolve, reject) => {
    const args = [
      "-hide_banner", "-loglevel", "error", "-nostdin",
      // Two decode threads per frame: several frames are read at once,
      // and a 4K HEVC decoder with default threads can exhaust memory.
      "-threads", "2",
      "-ss", String(Math.max(0, t)),
      "-i", url,
    ];
    if (thumb) {
      args.push(
        "-filter_complex",
        `[0:v]split=2[a][b];[a]scale=${Math.round(width)}:-2[big];[b]scale=${THUMB_W}:${THUMB_H},format=gray[small]`,
        "-map", "[big]", "-frames:v", "1", "-q:v", "5", "-f", "image2pipe", "-vcodec", "mjpeg", "pipe:1",
        "-map", "[small]", "-frames:v", "1", "-f", "rawvideo", "pipe:3",
      );
    } else {
      args.push(
        "-frames:v", "1",
        "-vf", `scale=${Math.round(width)}:-2`,
        "-q:v", "5",
        "-f", "image2pipe", "-vcodec", "mjpeg",
        "pipe:1",
      );
    }

    const proc = spawn(ffmpegPath, args, { stdio: ["ignore", "pipe", "pipe", ...(thumb ? ["pipe"] : [])] });
    const chunks = [];
    const thumbChunks = [];
    let stderr = "";

    const timer = setTimeout(() => {
      proc.kill("SIGKILL");
      reject(new Error(`Timed out reading the frame at ${t}s.`));
    }, timeoutMs);

    proc.stdout.on("data", c => chunks.push(c));
    if (thumb) proc.stdio[3].on("data", c => thumbChunks.push(c));
    proc.stderr.on("data", c => { if (stderr.length < 2000) stderr += c.toString(); });
    proc.on("error", err => { clearTimeout(timer); reject(err); });
    proc.on("close", code => {
      clearTimeout(timer);
      const buf = Buffer.concat(chunks);
      if (code === 0 && buf.length > 0) {
        const data = buf.toString("base64");
        if (!thumb) { resolve(data); return; }
        const small = Buffer.concat(thumbChunks);
        resolve({ data, thumb: small.length === THUMB_W * THUMB_H ? small : null });
      } else {
        reject(new Error(`ffmpeg could not read the frame at ${t}s: ${stderr.trim().slice(0, 300) || `exit ${code}`}`));
      }
    });
  });
}

// Several frames, a few at a time. A frame past the end of the video
// (or otherwise unreadable) is skipped rather than failing the batch.
// With `thumb`, each result also carries its grey thumbnail.
// With `deadline` (a Date.now() value), no new frame is started after
// it; the times never started are listed on the result as `.unread`,
// so the caller can ask for them again instead of the function timing out.
export async function grabFrames(url, times, width, concurrency = 4, thumb = false, deadline = Infinity) {
  const results = new Array(times.length).fill(null);
  const unread = [];
  let next = 0;

  async function worker() {
    while (next < times.length) {
      if (Date.now() > deadline) {
        while (next < times.length) unread.push(times[next++]);
        break;
      }
      const i = next++;
      try {
        const got = await grabFrame(url, times[i], width, 25000, thumb);
        const t = Math.round(times[i] * 100) / 100;
        results[i] = thumb ? { t, data: got.data, thumb: got.thumb } : { t, data: got };
      } catch (error) {
        console.warn(error.message);
      }
    }
  }

  await Promise.all(Array.from({ length: Math.min(concurrency, times.length) }, worker));
  const out = results.filter(Boolean);
  out.unread = unread.sort((a, b) => a - b);
  return out;
}

// ---- dead time ----
// Share of thumbnail pixels that changed by more than a little between
// two stills. Live play (skaters, the puck, a panning camera) changes far
// more than this; an intermission, an empty rink, a camera left on the
// bench or a frozen feed changes almost nothing.
const PIXEL_CHANGE = 14;   // grey levels; ignores compression noise
const DARK_LEVEL = 14;     // average grey below this = a covered or black frame

// Default 0.0015 (about 8 thumbnail pixels): only a black, frozen or
// paused picture counts as dead. A fixed camera far from the ice changes
// very few pixels during real play, so anything looser could drop live
// frames; warm-up and intermissions are for the admin's cuts instead.
export function stillThreshold() {
  const raw = process.env.SCAN_STILL_THRESHOLD;
  if (raw === undefined || raw === "") return 0.0015;
  const n = Number(raw);
  return Number.isFinite(n) && n >= 0 ? n : 0.0015;   // 0 turns the check off
}

function changedShare(a, b) {
  let changed = 0;
  for (let i = 0; i < a.length; i++) {
    if (Math.abs(a[i] - b[i]) > PIXEL_CHANGE) changed++;
  }
  return changed / a.length;
}

function isDark(a) {
  let sum = 0;
  for (let i = 0; i < a.length; i++) sum += a[i];
  return sum / a.length < DARK_LEVEL;
}

// Which frames (sorted by time) show nothing happening. A frame counts
// as dead only if it's black, or it barely differs from BOTH stills
// beside it (only one for the first and last), so a frame where play
// starts or stops is always kept. A frame without a thumbnail is kept.
export function deadFrames(frames, threshold = stillThreshold()) {
  const dead = new Array(frames.length).fill(false);
  if (!threshold) return dead;
  for (let i = 0; i < frames.length; i++) {
    const cur = frames[i].thumb;
    if (!cur) continue;
    if (isDark(cur)) { dead[i] = true; continue; }
    const near = [frames[i - 1], frames[i + 1]].filter(f => f && f.thumb).map(f => f.thumb);
    if (!near.length) continue;
    dead[i] = near.every(n => changedShare(cur, n) < threshold);
  }
  return dead;
}
