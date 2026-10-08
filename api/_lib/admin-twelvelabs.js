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
//     With assetId (from the upload below), the task reads that uploaded
//     file; otherwise a 24-hour signed link to the file in R2.
//   op "status": { tasks: [{ id, start, end, offset }] }
//     Replies { tasks: [{ id, status, segments?, error?, usd? }] }, with
//     segment times in the review player's time (seconds from 0).
//
// Twelve Labs fetches files from a link only up to 4 GB. Bigger files (up
// to 10 GB) are sent in pieces through its multipart upload, straight
// from R2, a few pieces per call so each call stays inside the function
// time limit; the browser keeps calling until it's done:
//   op "prepare": { gameVideoId } -> { mode: "url" } for 4 GB or less, or
//     { mode: "multipart", uploadId, assetId, chunkSize, totalChunks, headers }
//   op "upload":  { gameVideoId, uploadId, chunkSize, totalChunks, headers, from }
//     -> { next, done } (pieces from..next-1 sent and reported)
//   op "asset":   { assetId } -> { status: processing | ready | failed, error? }
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
const MAX_FILE_BYTES = 10 * 1024 ** 3;  // Pegasus 1.6 / multipart upload limit
const MAX_URL_BYTES = 4 * 1024 ** 3;    // what Twelve Labs fetches from a link
const UPLOAD_BUDGET_MS = 38 * 1000;     // per call, inside the 60 s limit
const MAX_WINDOW = 2 * 3600;            // per task
const MAX_VIDEO = 4 * 3600;             // when analysing part of a video
const TASK_ID_RE = /^[A-Za-z0-9_-]{6,80}$/;
const BIG_FILE_HELP = "Make a smaller copy (for example QuickTime: File > Export As > 1080p, or HandBrake's Fast 1080p30) and upload that with Add a video.";

async function loadVideo(gameVideoId) {
  const rows = await serviceSelect("game_videos", `select=*&id=eq.${encodeURIComponent(gameVideoId)}`);
  const video = rows[0];
  if (!video || !(await storagePathIsTrusted(video))) return null;
  return video;
}

async function objectSize(key) {
  const head = await r2Client().send(new HeadObjectCommand({ Bucket: process.env.R2_BUCKET_NAME, Key: key }));
  return Number(head.ContentLength) || 0;
}

async function prepare(req, res) {
  if (!r2Configured()) { res.status(501).json({ error: "Video storage isn't configured on the server." }); return; }
  const video = await loadVideo((req.body || {}).gameVideoId);
  if (!video) { res.status(404).json({ error: "Video not found." }); return; }
  const size = await objectSize(video.storage_path);
  if (size > MAX_FILE_BYTES) {
    res.status(400).json({ error: `This video file is ${(size / 1024 ** 3).toFixed(1)} GB; Twelve Labs takes up to 10 GB. ${BIG_FILE_HELP}` });
    return;
  }
  if (size <= MAX_URL_BYTES) { res.status(200).json({ mode: "url", size }); return; }
  const made = await tl("POST", "/assets/multipart-uploads", {
    filename: String(video.storage_path).split("/").pop().slice(0, 200) || "game.mp4",
    type: "video",
    total_size: size,
  });
  res.status(200).json({
    mode: "multipart", size,
    uploadId: made.upload_id, assetId: made.asset_id,
    chunkSize: made.chunk_size, totalChunks: made.total_chunks,
    headers: made.upload_headers || {},
  });
}

// Sends pieces from..., as many as fit in the time budget, then reports
// them. Pieces are numbered from 1; piece i is bytes (i-1)*chunkSize up to
// i*chunkSize-1 (the last may be shorter).
async function upload(req, res) {
  const { gameVideoId, uploadId, headers } = req.body || {};
  const chunkSize = Number(req.body && req.body.chunkSize);
  const totalChunks = Number(req.body && req.body.totalChunks);
  let next = Number(req.body && req.body.from) || 1;
  if (!TASK_ID_RE.test(String(uploadId || "")) || !Number.isInteger(chunkSize) || chunkSize <= 0 ||
      !Number.isInteger(totalChunks) || totalChunks <= 0 || totalChunks > 100000 || next < 1) {
    res.status(400).json({ error: "That upload isn't valid. Press Run AI to start again." });
    return;
  }
  const video = await loadVideo(gameVideoId);
  if (!video) { res.status(404).json({ error: "Video not found." }); return; }
  const size = await objectSize(video.storage_path);
  if (Math.ceil(size / chunkSize) !== totalChunks) {
    res.status(409).json({ error: "The video file changed since the upload started. Press Run AI to start again." });
    return;
  }
  const extra = headers && typeof headers === "object" ? Object.fromEntries(Object.entries(headers).filter(([k, v]) => /^[A-Za-z0-9-]{1,64}$/.test(k) && typeof v === "string")) : {};
  const parallel = chunkSize <= 32 * 1024 ** 2 ? 6 : chunkSize <= 128 * 1024 ** 2 ? 3 : 1;
  const started = Date.now();
  const sent = [];

  while (next <= totalChunks && Date.now() - started < UPLOAD_BUDGET_MS) {
    const count = Math.min(parallel, totalChunks - next + 1);
    const got = await tl("POST", `/assets/multipart-uploads/${encodeURIComponent(uploadId)}/presigned-urls`, { start: next, count });
    const urls = (got && got.upload_urls) || [];
    if (!urls.length) throw new Error("Twelve Labs didn't return upload links for the next pieces.");
    await Promise.all(urls.map(async u => {
      const i = Number(u.chunk_index);
      const a = (i - 1) * chunkSize;
      const b = Math.min(size, i * chunkSize) - 1;
      const obj = await r2Client().send(new GetObjectCommand({ Bucket: process.env.R2_BUCKET_NAME, Key: video.storage_path, Range: `bytes=${a}-${b}` }));
      const body = Buffer.from(await obj.Body.transformToByteArray());
      const put = await fetch(u.url, { method: "PUT", body, headers: extra });
      if (!put.ok) throw new Error(`Twelve Labs refused piece ${i} of the video (HTTP ${put.status}).`);
      const etag = put.headers.get("etag");
      if (!etag) throw new Error(`Twelve Labs didn't confirm piece ${i} of the video.`);
      sent.push({ chunk_index: i, proof: etag, proof_type: "etag", chunk_size: body.length });
    }));
    next = Math.max(...urls.map(u => Number(u.chunk_index))) + 1;
  }

  if (sent.length) {
    await tl("POST", `/assets/multipart-uploads/${encodeURIComponent(uploadId)}`, { completed_chunks: sent.sort((x, y) => x.chunk_index - y.chunk_index) });
  }
  res.status(200).json({ next, done: next > totalChunks });
}

async function assetStatus(req, res) {
  const assetId = String((req.body || {}).assetId || "");
  if (!TASK_ID_RE.test(assetId)) { res.status(400).json({ error: "Unknown upload." }); return; }
  try {
    const a = await tl("GET", `/assets/${encodeURIComponent(assetId)}`);
    res.status(200).json({ status: a.status || "processing", error: a.error ? (a.error.message || String(a.error)) : undefined });
  } catch (error) {
    if (error.status === 404) { res.status(200).json({ status: "missing" }); return; }
    throw error;
  }
}

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

// Twelve Labs' segments are stretches of video (like scenes); single
// moments inside them are "events" in a time_array field, each with its
// own start and end. So the segments here are stretches of play, and each
// shot is an event inside one.
//
// Told to leave out shots at the other net, it didn't reliably. So it's
// asked to list every shot attempt at either net and label each one
// (what it was, which end of the rink, which goalie faced it), and the
// filter below keeps only shots on goal against the tracked goalie.
function shotDefinition(jersey, side) {
  const team = jersey || "the tracked goalie's team colour";
  const net = side === "left" || side === "right"
    ? ` In this part of the game the tracked goalie defends the net at the ${side.toUpperCase()} end of the rink as this camera sees it.`
    : "";
  return {
    id: "play",
    description:
      `Stretches of ice hockey game play, split wherever play stops (a whistle or faceoff). The tracked goalie's team wears ${team}.${net} ` +
      "The stretches only organise the shot attempts listed in each one.",
    fields: [
      {
        name: "shots",
        type: "time_array",
        description:
          "Every shot attempt at EITHER net in this stretch, one event per attempt, each labelled with the fields below. " +
          "Each event starts when the puck leaves the shooter's stick and ends when the goalie saves it, the puck goes in, " +
          "or play moves on, usually a few seconds later. A rebound shot is its own event. Do not list passes, dump-ins, " +
          "carries, faceoffs or line changes as attempts. If there are none, return an empty list.",
        items: {
          type: "object",
          fields: [
            { name: "event", type: "string", enum: ["shot_on_goal", "missed_or_blocked", "not_a_shot"], description: "shot_on_goal if the puck reaches the goalie or goes in; missed_or_blocked if it misses the net or a skater blocks it; not_a_shot if this turns out to be a pass, dump-in or something else." },
            { name: "net", type: "string", enum: ["left", "right", "unclear"], description: "Which net the shot is aimed at: the one at the left end of the rink or the right end, as this camera sees the rink. unclear if you can't tell." },
            { name: "goalie", type: "string", enum: ["tracked", "other", "unclear"], description: `Which goalie faces the shot: tracked if that goalie's team wears ${team}, other if it's the opposing goalie, unclear if you can't tell.` },
            { name: "outcome", type: "string", enum: ["save", "goal", "unclear"], description: "save if the goalie stops it, goal only if the puck goes into the net, unclear if you can't tell." },
            { name: "confidence", type: "string", enum: ["high", "medium", "low"], description: "How sure you are about this event's labels." },
          ],
        },
      },
    ],
  };
}

// Keeps the shots on goal against the tracked goalie. side is the net
// side the admin set for this part of the game, or null.
function onTrackedNet(e, side) {
  if (e.event !== "shot_on_goal") return "not_shot";
  if (e.goalie === "other") return "other_net";
  if (side && e.net !== "unclear" && e.net !== side) return "other_net";
  if (!side && e.goalie !== "tracked") return "other_net";
  return "keep";
}

// Shots from a finished task, in the review player's time, plus what was
// left out. Also reads tasks sent before the labels existed.
function shotsFromResult(data, offset, side) {
  const level = c => (["high", "medium", "low"].includes(c) ? c : "low");
  const out = [];
  const left = { other_net: 0, not_shot: 0 };
  (Array.isArray(data.play) ? data.play : []).forEach(seg => {
    const events = seg && seg.metadata && Array.isArray(seg.metadata.shots) ? seg.metadata.shots : [];
    events.forEach(e => {
      const labelled = "event" in e || "net" in e || "goalie" in e;
      const verdict = labelled ? onTrackedNet(e, side) : "keep";
      if (verdict !== "keep") { left[verdict]++; return; }
      const a = Number(e.start_time) - offset;
      const b = Number(e.end_time) - offset;
      out.push({ start: a, end: b, t: a, outcome: ["save", "goal"].includes(e.outcome) ? e.outcome : "unclear", confidence: level(e.confidence) });
    });
  });
  (Array.isArray(data.shots) ? data.shots : []).forEach(s => {
    const m = (s && s.metadata) || {};
    const a = Number(s.start_time) - offset;
    const shot = Number(m.shot_time);
    out.push({ start: a, end: Number(s.end_time) - offset, t: Number.isFinite(shot) ? shot - offset : a, outcome: ["save", "goal"].includes(m.outcome) ? m.outcome : "unclear", confidence: level(m.confidence) });
  });
  const shots = out
    .filter(x => Number.isFinite(x.start) && Number.isFinite(x.end) && x.end >= x.start)
    .map(x => ({ ...x, start: Math.round(x.start * 10) / 10, end: Math.round(x.end * 10) / 10, t: Math.round(x.t * 10) / 10 }));
  return { shots, left };
}

async function checkAdmin(accessToken) {
  const caller = await verifyUser(accessToken);
  if (!caller) return { status: 401, error: "Invalid or expired session." };
  const profile = await getProfile(caller.id);
  if (!profile || profile.role !== "admin") return { status: 403, error: "Only an admin can use Twelve Labs." };
  return { caller };
}

async function start(req, res, caller) {
  const { gameVideoId, ranges, jersey, assetId } = req.body || {};
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

  const useAsset = TASK_ID_RE.test(String(assetId || ""));
  if (!useAsset) {
    const size = await objectSize(video.storage_path);
    if (size > MAX_URL_BYTES) {
      res.status(400).json({ error: `This video file is ${(size / 1024 ** 3).toFixed(1)} GB, over the 4 GB Twelve Labs fetches from a link; it has to be uploaded to Twelve Labs first. Press Run AI again to do that.` });
      return;
    }
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
      video: useAsset ? { type: "asset_id", asset_id: String(assetId) } : { type: "url", url },
      analysis_mode: "time_based_metadata",
      start_time: Math.round((w.start + offset) * 100) / 100,
      end_time: Math.round((w.end + offset) * 100) / 100,
      response_format: {
        type: "segment_definitions",
        segment_definitions: [shotDefinition(team, w.side)],
      },
    });
    tasks.push({ id: made.task_id || made._id, start: w.start, end: w.end, offset, side: w.side });
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
    const side = t.side === "left" || t.side === "right" ? t.side : null;
    const { shots: segments, left } = shotsFromResult(data, offset, side);

    // Billed on the task's window; logged once per task.
    const hours = Math.max(0, (Number(t.end) - Number(t.start)) / 3600);
    const usd = Math.round(hours * USD_PER_HOUR * 10000) / 10000;
    await logAiUsage({
      gameVideoId, requestedBy: caller.id, kind: "tl-segment", model: `twelvelabs-${MODEL}`,
      batchId: `tl:${id}`, tokens: NO_TOKENS, usd,
    });
    out.push({ id, status: "ready", segments, usd, leftOut: left });
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
    if (op === "prepare") { await prepare(req, res); return; }
    if (op === "upload") { await upload(req, res); return; }
    if (op === "asset") { await assetStatus(req, res); return; }
    res.status(400).json({ error: "Unknown operation." });
  } catch (error) {
    console.error(error);
    res.status(error.status && error.status < 500 ? 400 : 500).json({ error: error.message || "Twelve Labs request failed." });
  }
}
