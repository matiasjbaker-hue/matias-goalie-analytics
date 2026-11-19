// ============================================================
// POST /api/admin/convert-voice -- turn a WebM voice note into M4A
// (served through api/admin/[action].js)
// ============================================================
// Body: { accessToken, annotationId }
//
// Voice notes recorded in Chrome/Edge used to be saved as WebM/Opus,
// which Safari on older iPhones and Macs can't play. When playback fails
// on a .webm note, the page calls this: ffmpeg re-encodes it to AAC in an
// .m4a, the file goes back into the goalie's folder, the feedback row is
// pointed at it, and the old WebM is removed. Anyone who can already see
// the feedback (the goalie, their coach, an admin) can trigger it.

import { spawn } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";
import ffmpegPath from "ffmpeg-static";
import { verifyUser, getProfile, serviceSelect, SUPABASE_URL } from "./billing.js";
import { UUID_RE, callerCoachesGoalie } from "./supabase.js";
import { ffmpegAvailable } from "./frames.js";

const BUCKET = "voice-notes";
const MAX_BYTES = 25 * 1024 * 1024;

function svc(extra = {}) {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  return { apikey: key, Authorization: `Bearer ${key}`, ...extra };
}

function encodeM4a(inFile, outFile) {
  return new Promise((resolve, reject) => {
    const args = [
      "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
      "-i", inFile, "-vn",
      "-c:a", "aac", "-b:a", "64k", "-ac", "1",
      "-movflags", "+faststart",
      outFile,
    ];
    const proc = spawn(ffmpegPath, args, { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    const timer = setTimeout(() => { proc.kill("SIGKILL"); reject(new Error("Conversion took too long.")); }, 40000);
    proc.stderr.on("data", c => { if (stderr.length < 2000) stderr += c.toString(); });
    proc.on("error", err => { clearTimeout(timer); reject(err); });
    proc.on("close", code => {
      clearTimeout(timer);
      if (code === 0 && fs.existsSync(outFile) && fs.statSync(outFile).size > 0) resolve();
      else reject(new Error(`ffmpeg couldn't convert it: ${stderr.trim().slice(0, 300) || `exit ${code}`}`));
    });
  });
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }
  if (!process.env.SUPABASE_SERVICE_ROLE_KEY || !ffmpegAvailable()) {
    res.status(501).json({ error: "This server can't convert voice notes.", code: "convert_unavailable" });
    return;
  }

  const { accessToken, annotationId } = req.body || {};
  if (!/^\d+$/.test(String(annotationId || ""))) {
    res.status(400).json({ error: "Missing feedback id." });
    return;
  }

  const tmpIn = path.join(os.tmpdir(), `vn_${Date.now()}_${Math.random().toString(36).slice(2)}.webm`);
  const tmpOut = tmpIn.replace(/\.webm$/, ".m4a");

  try {
    const caller = await verifyUser(accessToken);
    if (!caller) { res.status(401).json({ error: "Invalid or expired session." }); return; }

    const rows = await serviceSelect("shot_annotations", `select=id,audio_path&id=eq.${annotationId}`);
    const ann = rows[0];
    if (!ann || !ann.audio_path) { res.status(404).json({ error: "No voice note on that feedback." }); return; }

    const oldPath = String(ann.audio_path);
    if (!/\.webm$/i.test(oldPath)) { res.status(200).json({ audio_path: oldPath, converted: false }); return; }

    // The note lives in the goalie's folder: <goalieId>/<file>
    const parts = oldPath.split("/");
    const goalieId = parts[0];
    if (parts.length !== 2 || !UUID_RE.test(goalieId) || /\.\./.test(oldPath)) {
      res.status(400).json({ error: "Unexpected voice note path." });
      return;
    }

    const profile = await getProfile(caller.id);
    const allowed =
      caller.id === goalieId ||
      (profile && profile.role === "admin") ||
      (profile && profile.role === "coach" && await callerCoachesGoalie(caller.id, goalieId, accessToken));
    if (!allowed) { res.status(403).json({ error: "You can't open this voice note." }); return; }

    const dl = await fetch(`${SUPABASE_URL}/storage/v1/object/${BUCKET}/${oldPath.split("/").map(encodeURIComponent).join("/")}`, { headers: svc() });
    if (!dl.ok) { res.status(404).json({ error: "The voice note file wasn't found." }); return; }
    const buf = Buffer.from(await dl.arrayBuffer());
    if (!buf.length || buf.length > MAX_BYTES) { res.status(400).json({ error: "That voice note can't be converted." }); return; }
    fs.writeFileSync(tmpIn, buf);

    await encodeM4a(tmpIn, tmpOut);

    const newPath = oldPath.replace(/\.webm$/i, ".m4a");
    const up = await fetch(`${SUPABASE_URL}/storage/v1/object/${BUCKET}/${newPath.split("/").map(encodeURIComponent).join("/")}`, {
      method: "POST",
      headers: svc({ "Content-Type": "audio/mp4", "x-upsert": "true" }),
      body: fs.readFileSync(tmpOut),
    });
    if (!up.ok) throw new Error(`upload failed (${up.status}): ${(await up.text()).slice(0, 200)}`);

    const upd = await fetch(`${SUPABASE_URL}/rest/v1/shot_annotations?id=eq.${annotationId}&audio_path=eq.${encodeURIComponent(oldPath)}`, {
      method: "PATCH",
      headers: svc({ "Content-Type": "application/json", Prefer: "return=minimal" }),
      body: JSON.stringify({ audio_path: newPath }),
    });
    if (!upd.ok) throw new Error(`couldn't update the feedback (${upd.status})`);

    // Old WebM no longer needed; failure here is harmless.
    await fetch(`${SUPABASE_URL}/storage/v1/object/${BUCKET}/${oldPath.split("/").map(encodeURIComponent).join("/")}`, { method: "DELETE", headers: svc() }).catch(() => {});

    res.status(200).json({ audio_path: newPath, converted: true });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: "Couldn't convert this voice note.", detail: String(error && error.message || error).slice(0, 300) });
  } finally {
    for (const f of [tmpIn, tmpOut]) { try { fs.unlinkSync(f); } catch (e) { /* already gone */ } }
  }
}
