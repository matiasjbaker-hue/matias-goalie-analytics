// ============================================================
// POST /api/admin/shot-model -- find shots with the GoalieIQ model
// (served through api/admin/[action].js)
// ============================================================
// Our own shot detector, trained on the games tagged in Review (ml/video/
// shots_modal.py). It runs on Modal: this route checks the caller is an
// admin, reads the video's row with the service key and hands Modal the
// file's R2 key, length and period marks (cuts, period starts, the
// goalie's net). Modal scans the uncut parts and returns likely shot times;
// the review screen turns them into moments to check.
//
// Body: { accessToken, op, gameVideoId, ... }
//   op "start":  { duration }  -> { callId }
//     duration: the player's length in seconds, used when the row has none.
//   op "status": { callId }    -> { status: running | ready | failed,
//                                   shots?: [{ t, score }], model?, minutes?, error? }
//
// Vercel environment variables: SHOT_MODEL_URL (the shot_api web endpoint
// that `modal deploy ml/video/shots_modal.py` prints) and SHOT_MODEL_SECRET
// (the same value as the `goalieiq-shot-api` Modal secret; see
// ml/video/setup_shot_api.sh).

import { verifyUser, getProfile, serviceSelect } from "./billing.js";
import { storagePathIsTrusted } from "./supabase.js";

const CALL_ID_RE = /^fc-[A-Za-z0-9]{8,64}$/;
const MAX_SECONDS = 6 * 3600;

function configured() {
  const url = process.env.SHOT_MODEL_URL || "";
  return /^https:\/\/[A-Za-z0-9.-]+\.modal\.run(\/.*)?$/.test(url) && (process.env.SHOT_MODEL_SECRET || "").length >= 32;
}

async function modal(body) {
  const res = await fetch(process.env.SHOT_MODEL_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ secret: process.env.SHOT_MODEL_SECRET, ...body }),
  });
  let data = {};
  try { data = await res.json(); } catch (e) { data = {}; }
  if (!res.ok) {
    const err = new Error(res.status === 401
      ? "The shot model rejected the server's key: SHOT_MODEL_SECRET in Vercel must match the goalieiq-shot-api secret on Modal."
      : (data.detail || `The shot model didn't answer (error ${res.status}).`));
    err.status = res.status === 400 ? 400 : 502;
    throw err;
  }
  return data;
}

async function checkAdmin(accessToken) {
  const caller = await verifyUser(accessToken);
  if (!caller) return { status: 401, error: "Invalid or expired session." };
  const profile = await getProfile(caller.id);
  if (!profile || profile.role !== "admin") return { status: 403, error: "Only an admin can run the shot model." };
  return { caller };
}

async function start(req, res) {
  const { gameVideoId, duration } = req.body || {};
  const rows = await serviceSelect("game_videos", `select=id,user_id,storage_path,duration_seconds,period_marks&id=eq.${encodeURIComponent(gameVideoId)}`);
  const video = rows[0];
  if (!video || !(await storagePathIsTrusted(video))) { res.status(404).json({ error: "Video not found." }); return; }

  const marks = video.period_marks && typeof video.period_marks === "object" ? video.period_marks : {};
  if (marks._net !== "left" && marks._net !== "right") {
    res.status(400).json({ error: "Set the goalie's net for the 1st period first (next to the period marks). The model needs it to watch the right end." });
    return;
  }
  const seconds = Number(video.duration_seconds) || Number(duration);
  if (!Number.isFinite(seconds) || seconds < 10 || seconds > MAX_SECONDS) {
    res.status(400).json({ error: "The video's length isn't known yet. Let it load in the player, then try again." });
    return;
  }

  // Only what the scan needs: cuts, period starts and net sides. AI results
  // and other review state stay behind.
  const keep = {};
  ["2", "3", "OT", "_cuts", "_net", "_sides"].forEach(k => { if (marks[k] !== undefined && marks[k] !== null) keep[k] = marks[k]; });

  const data = await modal({
    op: "start",
    film: { video_id: String(video.id), storage_path: video.storage_path, duration_seconds: seconds, period_marks: keep },
  });
  res.status(200).json({ callId: data.callId });
}

async function status(req, res) {
  const callId = String((req.body || {}).callId || "");
  if (!CALL_ID_RE.test(callId)) { res.status(400).json({ error: "Unknown run. Press Run AI to start again." }); return; }
  const data = await modal({ op: "status", callId });
  const shots = Array.isArray(data.shots)
    ? data.shots.map(s => ({ t: Number(s.t), score: Number(s.score) })).filter(s => Number.isFinite(s.t) && s.t >= 0 && Number.isFinite(s.score))
    : undefined;
  res.status(200).json({
    status: ["running", "ready", "failed"].includes(data.status) ? data.status : "failed",
    ...(shots ? { shots } : {}),
    ...(data.model ? { model: String(data.model).slice(0, 60) } : {}),
    ...(Number.isFinite(Number(data.minutes)) ? { minutes: Number(data.minutes) } : {}),
    ...(data.error ? { error: String(data.error).slice(0, 300) } : {}),
  });
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }
  if (!configured()) {
    res.status(503).json({ error: "The GoalieIQ model isn't connected yet: add SHOT_MODEL_URL and SHOT_MODEL_SECRET in Vercel, then redeploy." });
    return;
  }
  if (!process.env.SUPABASE_SERVICE_ROLE_KEY) {
    res.status(503).json({ error: "Server isn't configured for this yet (missing SUPABASE_SERVICE_ROLE_KEY)." });
    return;
  }
  try {
    const auth = await checkAdmin((req.body || {}).accessToken);
    if (auth.error) { res.status(auth.status).json({ error: auth.error }); return; }
    const op = (req.body || {}).op;
    if (op === "start") { await start(req, res); return; }
    if (op === "status") { await status(req, res); return; }
    res.status(400).json({ error: "Unknown operation." });
  } catch (error) {
    console.error(error);
    res.status(error.status && error.status < 500 ? 400 : 502).json({ error: error.message || "The shot model request failed." });
  }
}
