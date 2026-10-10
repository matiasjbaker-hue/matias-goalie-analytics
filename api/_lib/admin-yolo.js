// ============================================================
// POST /api/admin/yolo-worker -- job queue for the local YOLO/puck
// tracking worker (served through api/admin/[action].js)
// ============================================================
// tracking/worker.py runs on the admin's own PC, polls this endpoint
// for queued videos, processes one locally (YOLO player tracking +
// Kalman-filtered puck tracking + the math shot detector, all under
// tracking/), and reports shots back. The worker is not a logged-in
// Supabase user -- it's a trusted background process on a machine the
// admin controls -- so it authenticates with one shared secret
// (YOLO_WORKER_TOKEN) instead of an access token, and never holds
// Supabase or R2 credentials: every privileged read/write here happens
// server-side with the service role key.
//
// Body: { token, op, ... }
//   op "claim": {} ->
//     { job: null } when nothing is queued, or
//     { job: { id, signedUrl, durationSeconds, ranges, calibration } }
//     Picks the oldest queued video (or reclaims one stuck in
//     claimed/running past CLAIM_STALE_MS, e.g. a crashed worker),
//     using an optimistic PATCH (WHERE id AND the status just read) so
//     two workers can never claim the same row.
//     ranges: [[startSeconds, endSeconds], ...] to scan, i.e. the
//     video's duration minus any admin-marked cuts (period_marks._cuts
//     -- the same cuts the existing AI scan already skips); null means
//     "whole video" (duration unknown, or no cuts marked).
//     calibration: the video's yolo_calibration column verbatim (an
//     array of RinkCalibration records the browser's calibration tool
//     wrote), or null if the video hasn't been calibrated yet.
//   op "progress": { jobId, progress } -> { ok: true }
//     progress is 0..1. Only applied while that job is still "running"
//     (a late/duplicate progress post for a finished job is ignored).
//   op "complete": { jobId, shots: [{ t_s, confidence }, ...] } -> { ok: true, added }
//     Appends each shot into period_marks._candidates in the same
//     shape the browser's addReviewCandidate() already writes
//     (index.html), tagged src:"yolo" so the checklist can show
//     where a flag came from. Re-reads period_marks fresh right before
//     writing, so it merges with whatever the admin or another scan
//     added in the meantime instead of clobbering it.
//   op "fail": { jobId, error } -> { ok: true }
//
// Vercel environment variable: YOLO_WORKER_TOKEN (a long random
// secret; put the same value in tracking/.env on the admin's machine).

import crypto from "crypto";
import { GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { SUPABASE_URL, r2Configured, r2Client, storagePathIsTrusted } from "./supabase.js";

const JOB_ID_RE = /^[1-9][0-9]{0,18}$/;
const MAX_CANDIDATES = 2000;
const MAX_SHOTS_PER_CALL = 500;
const CLAIM_STALE_MS = 2 * 60 * 60 * 1000; // a running job stuck this long is treated as a crashed worker

function workerTokenConfigured() {
  return String(process.env.YOLO_WORKER_TOKEN || "").trim();
}

// Constant-time compare so a mistyped token can't be brute-forced via
// response timing. Different-length inputs are rejected outright
// (timingSafeEqual requires equal-length buffers).
function tokenIsValid(given) {
  const expected = workerTokenConfigured();
  if (!expected || typeof given !== "string") return false;
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

function serviceHeaders(extra = {}) {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  return { apikey: key, Authorization: `Bearer ${key}`, ...extra };
}

async function serviceSelect(query) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/game_videos?${query}`, { headers: serviceHeaders() });
  if (!res.ok) throw new Error(`Supabase ${res.status} reading game_videos`);
  return res.json();
}

// PATCH ...&id=eq.<id>&yolo_status=eq.<expectedStatus> -- the WHERE
// clause doubles as an optimistic lock: if someone else already moved
// the row past expectedStatus, zero rows match and zero come back.
async function claimPatch(id, expectedStatus, patch) {
  const query = `id=eq.${id}&yolo_status=eq.${encodeURIComponent(expectedStatus)}`;
  const res = await fetch(`${SUPABASE_URL}/rest/v1/game_videos?${query}`, {
    method: "PATCH",
    headers: serviceHeaders({ "Content-Type": "application/json", Prefer: "return=representation" }),
    body: JSON.stringify(patch),
  });
  if (!res.ok) throw new Error(`Supabase ${res.status} claiming game_video ${id}: ${await res.text()}`);
  const rows = await res.json();
  return rows[0] || null;
}

async function servicePatch(id, patch) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/game_videos?id=eq.${id}`, {
    method: "PATCH",
    headers: serviceHeaders({ "Content-Type": "application/json", Prefer: "return=representation" }),
    body: JSON.stringify(patch),
  });
  if (!res.ok) throw new Error(`Supabase ${res.status} updating game_video ${id}: ${await res.text()}`);
  const rows = await res.json();
  return rows[0] || null;
}

// Whole duration minus admin-marked cuts (period_marks._cuts, the same
// list the existing AI scan already jumps over -- see index.html's
// reviewCuts/mergeReviewCuts). null (via either arg) means "no cut
// data to work from": the worker treats that as "scan everything".
function rangesFromCuts(durationSeconds, cuts) {
  if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) return null;
  const merged = (Array.isArray(cuts) ? cuts : [])
    .filter(r => Array.isArray(r) && Number.isFinite(Number(r[0])) && Number(r[1]) > Number(r[0]))
    .map(r => [Math.max(0, Number(r[0])), Math.min(durationSeconds, Number(r[1]))])
    .sort((a, b) => a[0] - b[0])
    .reduce((out, r) => {
      const last = out[out.length - 1];
      if (last && r[0] <= last[1] + 0.05) { last[1] = Math.max(last[1], r[1]); }
      else { out.push(r); }
      return out;
    }, []);
  if (!merged.length) return [[0, durationSeconds]];
  const ranges = [];
  let cursor = 0;
  for (const [a, b] of merged) {
    if (a > cursor) ranges.push([cursor, a]);
    cursor = Math.max(cursor, b);
  }
  if (cursor < durationSeconds) ranges.push([cursor, durationSeconds]);
  return ranges;
}

async function claim(req, res) {
  if (!r2Configured()) { res.status(501).json({ error: "Video storage isn't configured on the server." }); return; }

  const staleBefore = new Date(Date.now() - CLAIM_STALE_MS).toISOString();
  const candidates = await serviceSelect(
    `select=*&or=(yolo_status.eq.queued,and(yolo_status.in.(claimed,running),yolo_started_at.lt.${encodeURIComponent(staleBefore)}))` +
    `&order=yolo_requested_at.asc.nullsfirst&limit=5`
  );

  for (const row of candidates) {
    const claimed = await claimPatch(row.id, row.yolo_status, {
      yolo_status: "running",
      yolo_started_at: new Date().toISOString(),
      yolo_error: null,
    });
    if (!claimed) continue; // someone/something else claimed it first; try the next candidate

    if (!(await storagePathIsTrusted(claimed))) {
      await servicePatch(claimed.id, { yolo_status: "failed", yolo_error: "Video storage path failed a trust check." });
      continue;
    }

    const signedUrl = await getSignedUrl(
      r2Client(), new GetObjectCommand({ Bucket: process.env.R2_BUCKET_NAME, Key: claimed.storage_path }),
      { expiresIn: 60 * 60 * 24 }
    );
    const cuts = claimed.period_marks && Array.isArray(claimed.period_marks._cuts) ? claimed.period_marks._cuts : [];
    res.status(200).json({
      job: {
        id: claimed.id,
        signedUrl,
        durationSeconds: Number.isFinite(claimed.duration_seconds) ? claimed.duration_seconds : null,
        ranges: rangesFromCuts(claimed.duration_seconds, cuts),
        calibration: claimed.yolo_calibration || null,
      },
    });
    return;
  }

  res.status(200).json({ job: null });
}

async function progress(req, res) {
  const id = String((req.body || {}).jobId || "");
  const value = Number((req.body || {}).progress);
  if (!JOB_ID_RE.test(id) || !Number.isFinite(value)) { res.status(400).json({ error: "Invalid progress report." }); return; }
  const clamped = Math.max(0, Math.min(1, value));
  const query = `id=eq.${id}&yolo_status=eq.running`;
  await fetch(`${SUPABASE_URL}/rest/v1/game_videos?${query}`, {
    method: "PATCH",
    headers: serviceHeaders({ "Content-Type": "application/json", Prefer: "return=minimal" }),
    body: JSON.stringify({ yolo_progress: clamped }),
  });
  res.status(200).json({ ok: true });
}

function candidateFromShot(shot) {
  const t = Math.round(Number(shot && shot.t_s) * 100) / 100;
  const c = Math.round((Number(shot && shot.confidence) || 0) * 100) / 100;
  if (!Number.isFinite(t) || t < 0 || t > 6 * 3600) return null;
  // src, not "source": matches the existing terse t/c/g/s/e keys this
  // record shape already uses (index.html's reviewCandidateRecord).
  return { t, c: Math.max(0, Math.min(1, c)), src: "yolo" };
}

async function complete(req, res) {
  const id = String((req.body || {}).jobId || "");
  const shots = (req.body || {}).shots;
  if (!JOB_ID_RE.test(id) || !Array.isArray(shots) || shots.length > MAX_SHOTS_PER_CALL) {
    res.status(400).json({ error: "Invalid completion report." });
    return;
  }

  const rows = await serviceSelect(`select=period_marks&id=eq.${id}`);
  const current = rows[0];
  if (!current) { res.status(404).json({ error: "Video not found." }); return; }

  const added = shots.map(candidateFromShot).filter(Boolean);
  const existing = Array.isArray(current.period_marks && current.period_marks._candidates)
    ? current.period_marks._candidates : [];
  const merged = [...existing, ...added].slice(-MAX_CANDIDATES);

  await servicePatch(id, {
    period_marks: { ...(current.period_marks || {}), _candidates: merged },
    yolo_status: "done",
    yolo_progress: 1,
    yolo_finished_at: new Date().toISOString(),
    yolo_error: null,
  });
  res.status(200).json({ ok: true, added: added.length });
}

async function fail(req, res) {
  const id = String((req.body || {}).jobId || "");
  if (!JOB_ID_RE.test(id)) { res.status(400).json({ error: "Invalid job id." }); return; }
  const message = String((req.body || {}).error || "The worker reported an unknown error.").slice(0, 500);
  await servicePatch(id, { yolo_status: "failed", yolo_error: message, yolo_finished_at: new Date().toISOString() });
  res.status(200).json({ ok: true });
}

export default async function handler(req, res) {
  if (req.method !== "POST") { res.status(405).json({ error: "Method not allowed" }); return; }
  if (!workerTokenConfigured()) { res.status(503).json({ error: "The YOLO worker isn't set up yet: add YOLO_WORKER_TOKEN in Vercel, then redeploy." }); return; }
  if (!process.env.SUPABASE_SERVICE_ROLE_KEY) { res.status(503).json({ error: "Server isn't configured for this yet (missing SUPABASE_SERVICE_ROLE_KEY)." }); return; }
  if (!tokenIsValid((req.body || {}).token)) { res.status(401).json({ error: "Invalid worker token." }); return; }

  try {
    const op = (req.body || {}).op;
    if (op === "claim") { await claim(req, res); return; }
    if (op === "progress") { await progress(req, res); return; }
    if (op === "complete") { await complete(req, res); return; }
    if (op === "fail") { await fail(req, res); return; }
    res.status(400).json({ error: "Unknown operation." });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: "YOLO worker request failed." });
  }
}
