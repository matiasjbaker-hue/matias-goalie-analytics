// ============================================================
// POST /api/admin/make-clip -- cut one shot out of a game as an MP4
// (served through api/admin/[action].js)
// ============================================================
// Body: { accessToken, gameVideoId, start, end }
//
// Game film arrives in whatever the camera wrote: often iPhone .mov
// files in HEVC, which some browsers can't play. When the admin
// approves a review, each shot gets its own short clip re-encoded to
// H.264 MP4 (plays everywhere, starts instantly). ffmpeg reads only the
// needed stretch of the source straight from R2 over a signed URL, the
// clip goes back into the goalie's folder, and a game_videos row
// (status "clip") is returned for the shot to point at.

import { spawn } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";
import { GetObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import ffmpegPath from "ffmpeg-static";
import { verifyUser, getProfile, serviceSelect, SUPABASE_URL } from "./billing.js";
import { r2Configured, r2Client, storagePathIsTrusted } from "./supabase.js";
import { ffmpegAvailable } from "./frames.js";

const MAX_CLIP_SECONDS = 30;

export function encodeClip(sourceUrl, start, duration, outFile) {
  return new Promise((resolve, reject) => {
    const args = [
      "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
      "-ss", String(start),
      "-i", sourceUrl,
      "-t", String(duration),
      // 720p at most, never upscaled; even dimensions for H.264.
      "-vf", "scale='min(1280,iw)':-2",
      "-c:v", "libx264", "-preset", "veryfast", "-crf", "26", "-pix_fmt", "yuv420p",
      "-c:a", "aac", "-b:a", "96k", "-ac", "2",
      "-movflags", "+faststart",
      outFile,
    ];
    const proc = spawn(ffmpegPath, args, { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    const timer = setTimeout(() => { proc.kill("SIGKILL"); reject(new Error("Clip encoding took too long.")); }, 50000);
    proc.stderr.on("data", c => { if (stderr.length < 2000) stderr += c.toString(); });
    proc.on("error", err => { clearTimeout(timer); reject(err); });
    proc.on("close", code => {
      clearTimeout(timer);
      if (code === 0 && fs.existsSync(outFile) && fs.statSync(outFile).size > 0) resolve();
      else reject(new Error(`ffmpeg couldn't make the clip: ${stderr.trim().slice(0, 300) || `exit ${code}`}`));
    });
  });
}

async function serviceInsert(table, row) {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${encodeURIComponent(table)}`, {
    method: "POST",
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
      Prefer: "return=representation",
    },
    body: JSON.stringify(row),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`Supabase ${res.status} inserting into ${table}: ${text}`);
  return JSON.parse(text)[0];
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  if (!process.env.SUPABASE_SERVICE_ROLE_KEY || !r2Configured() || !ffmpegAvailable()) {
    res.status(501).json({ error: "This server can't make clips.", code: "clips_unavailable" });
    return;
  }

  const { accessToken, gameVideoId } = req.body || {};
  const start = Number(req.body && req.body.start);
  const end = Number(req.body && req.body.end);

  if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end <= start || end - start > MAX_CLIP_SECONDS) {
    res.status(400).json({ error: `Clips must be under ${MAX_CLIP_SECONDS} seconds.` });
    return;
  }

  let outFile = null;

  try {
    const caller = await verifyUser(accessToken);
    if (!caller) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }

    const callerProfile = await getProfile(caller.id);
    if (!callerProfile || callerProfile.role !== "admin") {
      res.status(403).json({ error: "Only an admin can make clips." });
      return;
    }

    const rows = await serviceSelect("game_videos", `select=*&id=eq.${encodeURIComponent(gameVideoId)}`);
    const source = rows[0];
    if (!source || !(await storagePathIsTrusted(source))) {
      res.status(404).json({ error: "Video not found." });
      return;
    }

    const sourceUrl = await getSignedUrl(
      r2Client(),
      new GetObjectCommand({ Bucket: process.env.R2_BUCKET_NAME, Key: source.storage_path }),
      { expiresIn: 60 * 15 }
    );

    outFile = path.join(os.tmpdir(), `clip_${source.id}_${Date.now()}.mp4`);
    await encodeClip(sourceUrl, start, end - start, outFile);

    const key = `${source.user_id}/clips/${Date.now()}_${source.id}_${Math.round(start)}s.mp4`;
    await r2Client().send(new PutObjectCommand({
      Bucket: process.env.R2_BUCKET_NAME,
      Key: key,
      Body: fs.readFileSync(outFile),
      ContentType: "video/mp4",
    }));

    const clip = await serviceInsert("game_videos", {
      user_id: source.user_id,
      game_id: source.game_id,
      storage_path: key,
      status: "clip",
      review_status: "approved",
    });

    res.status(200).json({ gameVideoId: clip.id });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: "Couldn't make this clip." });
  } finally {
    if (outFile) { try { fs.unlinkSync(outFile); } catch (e) { /* already gone */ } }
  }
}
