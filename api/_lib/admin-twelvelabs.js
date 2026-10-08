// ============================================================
// POST /api/admin/twelvelabs -- find shots with Twelve Labs (Pegasus)
// (served through api/admin/[action].js)
// ============================================================
// Twelve Labs' video model watches the footage itself, rather than a
// still every second or so. Its "time-based metadata" mode returns
// timestamped segments matching a description we write: here, one
// segment per shot on the tracked goalie. The review screen turns those
// into moments to check.
//
// Body: { accessToken, op, gameVideoId, ... }
//   op "start":  { ranges: [{ start, end, side }], jersey }
//     One analysis task per range (the uncut parts of the game, split at
//     period marks), so warm-up and intermissions aren't analysed or
//     billed: Twelve Labs bills the start_time-end_time window of each
//     task. Replies { tasks: [{ id, start, end, offset }] }.
//   op "status": { tasks: [{ id, start, end, offset }] }
//     Replies { tasks: [{ id, status, segments?, error?, usd? }] }, with
//     segment times in the review player's time (seconds from 0).
//
// Vercel environment variable: TWELVELABS_API_KEY (from the Twelve Labs
// dashboard's API Keys page).

import { spawn } from "child_process";
import { GetObjectCommand, HeadObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import ffmpegPath from "ffmpeg-static";
import { verifyUser, getProfile, serviceSelect } from "./billing.js";
import { r2Configured, r2Client, storagePathIsTrusted } from "./supabase.js";
import { ffmpegAvailable } from "./frames.js";
import { logAiUsage, NO_TOKENS } from "./ai-cost.js";

const API = "https://api.twelvelabs.io/v1.3";
const MODEL = "pegasus1.6";
const USD_PER_HOUR = 1.75;              // Analyze API, per hour of video, per segment definition
const MAX_FILE_BYTES = 10 * 1024 ** 3;  // Pegasus 1.6 limit
const MAX_WINDOW = 2 * 3600;            // per task
const MAX_VIDEO = 4 * 3600;             // when analysing part of a video
const TASK_ID_RE = /^[A-Za-z0-9_-]{6,80}$/;

function apiKey() {
  return String(process.env.TWELVELABS_API_KEY || "").trim();
}

async function tl(method, path, body) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { "x-api-key": apiKey(), ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
  if (!res.ok) {
    const msg = (data && (data.message || data.code)) || text.slice(0, 200) || `HTTP ${res.status}`;
    const err = new Error(`Twelve Labs: ${msg}`);
    err.status = res.status;
    throw err;
  }
  return data;
}

// The video's internal start time and length. Twelve Labs' timestamps
// use the file's own clock, which for some cameras doesn't start at 0;
// the review player always starts at 0.
function probe(url) {
  return new Promise(resolve => {
    if (!ffmpegAvailable()) { resolve({ offset: 0, duration: null }); return; }
    const proc = spawn(ffmpegPath, ["-hide_banner", "-nostdin", "-i", url], { stdio: ["ignore", "ignore", "pipe"] });
    let err = "";
    const timer = setTimeout(() => proc.kill("SIGKILL"), 20000);
    proc.stderr.on("data", c => { if (err.length < 20000) err += c.toString(); });
    proc.on("close", () => {
      clearTimeout(timer);
      const d = /Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)/.exec(err);
      const s = /start:\s*(-?\d+(?:\.\d+)?)/.exec(err);
      resolve({
        offset: s ? Math.max(0, Number(s[1])) : 0,
        duration: d ? Number(d[1]) * 3600 + Number(d[2]) * 60 + Number(d[3]) : null,
      });
    });
    proc.on("error", () => { clearTimeout(timer); resolve({ offset: 0, duration: null }); });
  });
}

function clean(text, max) {
  return String(text || "").replace(/[^\w #/-]/g, "").replace(/\s+/g, " ").trim().slice(0, max);
}

function shotDefinition(jersey, side) {
  const who = jersey
    ? `The tracked goalie's team wears ${jersey}.`
    : "The tracked goalie is the one defending the net named below.";
  const net = side === "left" || side === "right"
    ? ` In this part of the game the tracked goalie's net is on the ${side.toUpperCase()} side of the picture.`
    : "";
  return {
    id: "shots",
    description:
      `A shot on goal against the tracked goalie in an ice hockey game. ${who}${net} ` +
      "One segment per shot attempt: an opposing player shoots the puck at the tracked goalie's net " +
      "(wrist, slap, snap, backhand, tip, deflection, one-timer, wraparound or rebound), starting a couple of " +
      "seconds before the release and ending when the goalie saves it, the puck goes in, or play moves on. " +
      "A rebound shot right after another shot is its own segment. Do not include shots on the other goalie, " +
      "passes, dump-ins, carries, board battles, faceoffs, line changes, stoppages, celebrations or replays.",
    fields: [
      { name: "shot_time", type: "timestamp", format: "seconds", description: "The moment the puck leaves the shooter's stick." },
      { name: "outcome", type: "string", enum: ["save", "goal", "missed_net", "unclear"], description: "save if the goalie stops it, goal only if the puck goes into the tracked goalie's net, missed_net if it misses the net or is blocked before reaching it, unclear if you can't tell." },
      { name: "confidence", type: "string", enum: ["high", "medium", "low"], description: "How sure you are that this is a shot on the tracked goalie's net." },
    ],
  };
}

async function checkAdmin(accessToken) {
  const caller = await verifyUser(accessToken);
  if (!caller) return { status: 401, error: "Invalid or expired session." };
  const profile = await getProfile(caller.id);
  if (!profile || profile.role !== "admin") return { status: 403, error: "Only an admin can use Twelve Labs." };
  return { caller };
}

async function start(req, res, caller) {
  const { gameVideoId, ranges, jersey } = req.body || {};
  if (!Array.isArray(ranges) || !ranges.length || ranges.length > 20) {
    res.status(400).json({ error: "Nothing to analyse: the whole video is cut." });
    return;
  }
  if (!r2Configured()) {
    res.status(501).json({ error: "Video storage isn't configured on the server." });
    return;
  }

  const rows = await serviceSelect("game_videos", `select=*&id=eq.${encodeURIComponent(gameVideoId)}`);
  const video = rows[0];
  if (!video || !(await storagePathIsTrusted(video))) {
    res.status(404).json({ error: "Video not found." });
    return;
  }

  const head = await r2Client().send(new HeadObjectCommand({ Bucket: process.env.R2_BUCKET_NAME, Key: video.storage_path }));
  const size = Number(head.ContentLength) || 0;
  if (size > MAX_FILE_BYTES) {
    res.status(400).json({ error: `This video file is ${(size / 1024 ** 3).toFixed(1)} GB; Twelve Labs takes up to 10 GB. Upload a smaller copy (for example exported at 1080p) with Add a video.` });
    return;
  }

  // Long enough for Twelve Labs to fetch the file even if tasks queue.
  const url = await getSignedUrl(r2Client(), new GetObjectCommand({ Bucket: process.env.R2_BUCKET_NAME, Key: video.storage_path }), { expiresIn: 60 * 60 * 24 });
  const { offset, duration } = await probe(url);
  if (duration && duration > MAX_VIDEO) {
    res.status(400).json({ error: "Twelve Labs can analyse videos up to 4 hours long, and this one is longer." });
    return;
  }

  const team = clean(jersey, 40);
  const windows = [];
  for (const r of ranges) {
    let a = Math.max(0, Number(r && r.start));
    const b = Math.min(duration || Infinity, Number(r && r.end));
    if (!Number.isFinite(a) || !Number.isFinite(b) || b - a < 2) continue;
    const side = r.side === "left" || r.side === "right" ? r.side : null;
    while (b - a >= 2) {
      const end = Math.min(b, a + MAX_WINDOW);
      windows.push({ start: a, end, side });
      a = end;
    }
  }
  if (!windows.length) {
    res.status(400).json({ error: "Nothing to analyse: the parts left after cutting are too short." });
    return;
  }

  const tasks = [];
  for (let i = 0; i < windows.length; i++) {
    const w = windows[i];
    const made = await tl("POST", "/analyze/tasks", {
      model_name: MODEL,
      custom_id: `giq-${video.id}-${Date.now()}-${i}`,
      video: { type: "url", url },
      analysis_mode: "time_based_metadata",
      start_time: Math.round((w.start + offset) * 100) / 100,
      end_time: Math.round((w.end + offset) * 100) / 100,
      response_format: {
        type: "segment_definitions",
        segment_definitions: [shotDefinition(team, w.side)],
      },
    });
    tasks.push({ id: made.task_id || made._id, start: w.start, end: w.end, offset });
  }

  res.status(200).json({ tasks });
}

async function status(req, res, caller) {
  const { gameVideoId, tasks } = req.body || {};
  if (!Array.isArray(tasks) || !tasks.length || tasks.length > 40) {
    res.status(400).json({ error: "No Twelve Labs tasks to check." });
    return;
  }
  const out = [];
  for (const t of tasks) {
    const id = String(t && t.id || "");
    if (!TASK_ID_RE.test(id)) { out.push({ id, status: "failed", error: "Unknown task." }); continue; }
    const offset = Number(t.offset) || 0;
    let task;
    try {
      task = await tl("GET", `/analyze/tasks/${encodeURIComponent(id)}`);
    } catch (error) {
      out.push({ id, status: error.status === 404 ? "failed" : "unknown", error: error.message });
      continue;
    }
    if (task.status === "failed" || task.status === "canceled") {
      out.push({ id, status: "failed", error: (task.error && task.error.message) || `The analysis was ${task.status}.` });
      continue;
    }
    if (task.status !== "ready") {
      out.push({ id, status: task.status || "processing" });
      continue;
    }

    let data = {};
    try { data = JSON.parse((task.result && task.result.data) || "{}"); } catch (e) { data = {}; }
    const segments = (Array.isArray(data.shots) ? data.shots : []).map(s => {
      const m = (s && s.metadata) || {};
      const a = Number(s.start_time) - offset;
      const b = Number(s.end_time) - offset;
      const shot = Number(m.shot_time);
      return {
        start: Math.round(a * 10) / 10,
        end: Math.round(b * 10) / 10,
        t: Math.round((Number.isFinite(shot) ? shot - offset : a) * 10) / 10,
        outcome: ["save", "goal", "missed_net", "unclear"].includes(m.outcome) ? m.outcome : "unclear",
        confidence: ["high", "medium", "low"].includes(m.confidence) ? m.confidence : "low",
      };
    }).filter(s => Number.isFinite(s.start) && Number.isFinite(s.end) && s.end >= s.start);

    // Billed on the task's window; logged once per task.
    const hours = Math.max(0, (Number(t.end) - Number(t.start)) / 3600);
    const usd = Math.round(hours * USD_PER_HOUR * 10000) / 10000;
    await logAiUsage({
      gameVideoId, requestedBy: caller.id, kind: "tl-segment", model: `twelvelabs-${MODEL}`,
      batchId: `tl:${id}`, tokens: NO_TOKENS, usd,
    });
    out.push({ id, status: "ready", segments, usd });
  }
  res.status(200).json({ tasks: out });
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }
  if (!apiKey()) {
    res.status(503).json({ error: "Twelve Labs isn't set up yet: add TWELVELABS_API_KEY in Vercel, then redeploy." });
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
    if (op === "start") { await start(req, res, auth.caller); return; }
    if (op === "status") { await status(req, res, auth.caller); return; }
    res.status(400).json({ error: "Unknown operation." });
  } catch (error) {
    console.error(error);
    res.status(error.status && error.status < 500 ? 400 : 500).json({ error: error.message || "Twelve Labs request failed." });
  }
}
