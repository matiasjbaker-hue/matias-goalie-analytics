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

// One JPEG at `t` seconds, scaled to `width` pixels wide, as base64.
export function grabFrame(url, t, width, timeoutMs = 25000) {
  return new Promise((resolve, reject) => {
    const args = [
      "-hide_banner", "-loglevel", "error", "-nostdin",
      "-ss", String(Math.max(0, t)),
      "-i", url,
      "-frames:v", "1",
      "-vf", `scale=${Math.round(width)}:-2`,
      "-q:v", "5",
      "-f", "image2pipe", "-vcodec", "mjpeg",
      "pipe:1",
    ];

    const proc = spawn(ffmpegPath, args, { stdio: ["ignore", "pipe", "pipe"] });
    const chunks = [];
    let stderr = "";

    const timer = setTimeout(() => {
      proc.kill("SIGKILL");
      reject(new Error(`Timed out reading the frame at ${t}s.`));
    }, timeoutMs);

    proc.stdout.on("data", c => chunks.push(c));
    proc.stderr.on("data", c => { if (stderr.length < 2000) stderr += c.toString(); });
    proc.on("error", err => { clearTimeout(timer); reject(err); });
    proc.on("close", code => {
      clearTimeout(timer);
      const buf = Buffer.concat(chunks);
      if (code === 0 && buf.length > 0) {
        resolve(buf.toString("base64"));
      } else {
        reject(new Error(`ffmpeg could not read the frame at ${t}s: ${stderr.trim().slice(0, 300) || `exit ${code}`}`));
      }
    });
  });
}

// Several frames, a few at a time. A frame past the end of the video
// (or otherwise unreadable) is skipped rather than failing the batch.
export async function grabFrames(url, times, width, concurrency = 4) {
  const results = new Array(times.length).fill(null);
  let next = 0;

  async function worker() {
    while (next < times.length) {
      const i = next++;
      try {
        results[i] = { t: Math.round(times[i] * 100) / 100, data: await grabFrame(url, times[i], width) };
      } catch (error) {
        console.warn(error.message);
      }
    }
  }

  await Promise.all(Array.from({ length: Math.min(concurrency, times.length) }, worker));
  return results.filter(Boolean);
}
