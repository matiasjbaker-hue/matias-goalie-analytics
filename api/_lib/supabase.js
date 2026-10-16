// ============================================================
// SHARED SERVER HELPERS (Supabase as the caller, R2, errors)
// ============================================================
// Files under api/_lib are not deployed as endpoints (leading "_").
// Every endpoint used to carry its own copy of these; one copy means
// a security fix lands everywhere at once.

import { S3Client, ListObjectsV2Command } from "@aws-sdk/client-s3";

export const SUPABASE_URL = "https://iiuqxxrrruvwvfehrzic.supabase.co";
// Publishable key: safe to ship, RLS is what protects the data.
export const SUPABASE_ANON_KEY = "sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ";

function userHeaders(accessToken, extra = {}) {
  return { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${accessToken}`, ...extra };
}

// Supabase access tokens are JWTs; anything else is rejected before a
// network call so junk input never reaches Supabase.
function looksLikeJwt(token) {
  return typeof token === "string" && token.length < 4096 && /^[\w-]+\.[\w-]+\.[\w-]+$/.test(token);
}

export async function verifyUser(accessToken) {
  if (!looksLikeJwt(accessToken)) return null;
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: userHeaders(accessToken) });
  if (!res.ok) return null;
  const data = await res.json();
  return data && data.id ? data : null;
}

// SELECT with the caller's own token, so RLS decides what comes back.
export async function userSelect(table, query, accessToken) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${encodeURIComponent(table)}?${query}`, {
    headers: userHeaders(accessToken),
  });
  if (!res.ok) throw new Error(`Supabase GET ${table} failed: ${res.status}`);
  const data = await res.json();
  return Array.isArray(data) ? data : [];
}

export async function userDelete(table, query, accessToken) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${encodeURIComponent(table)}?${query}`, {
    method: "DELETE",
    headers: userHeaders(accessToken, { Prefer: "return=representation" }),
  });
  if (!res.ok) throw new Error(`Supabase DELETE ${table} failed: ${res.status} ${await res.text()}`);
  return res.json();
}

export async function userInsert(table, rows, accessToken) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${encodeURIComponent(table)}`, {
    method: "POST",
    headers: userHeaders(accessToken, { "Content-Type": "application/json", Prefer: "return=representation" }),
    body: JSON.stringify(rows),
  });
  const text = await res.text();
  if (!res.ok) {
    const err = new Error(`Supabase INSERT ${table} failed: ${res.status} ${text}`);
    err.status = res.status;
    err.body = text;
    throw err;
  }
  return text ? JSON.parse(text) : [];
}

export async function userUpdate(table, query, patch, accessToken) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${encodeURIComponent(table)}?${query}`, {
    method: "PATCH",
    headers: userHeaders(accessToken, { "Content-Type": "application/json", Prefer: "return=representation" }),
    body: JSON.stringify(patch),
  });
  if (!res.ok) throw new Error(`Supabase PATCH ${table} failed: ${res.status} ${await res.text()}`);
  return res.json();
}

// RPC that answers true/false for the caller (my_has_access, ...).
export async function userRpcIsTrue(fn, accessToken) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: userHeaders(accessToken, { "Content-Type": "application/json" }),
    body: "{}",
  });
  if (!res.ok) return false;
  return (await res.json()) === true;
}

// Paywall: goalies need active access (comp / trial / paid). Coaches
// and admin always pass. Evaluated in the database.
export const callerHasAccess = token => userRpcIsTrue("my_has_access", token);
// AI features: Goalie Plus (plus comp, trials, coaches, admin).
export const callerHasAiAccess = token => userRpcIsTrue("my_has_ai_access", token);

export async function callerRole(userId, accessToken) {
  const rows = await userSelect("profiles", `select=role&id=eq.${encodeURIComponent(userId)}`, accessToken);
  return rows[0] ? rows[0].role : null;
}

// ---- R2 ----

export function r2Configured() {
  return !!(process.env.R2_ACCOUNT_ID && process.env.R2_ACCESS_KEY_ID &&
    process.env.R2_SECRET_ACCESS_KEY && process.env.R2_BUCKET_NAME);
}

export function r2Client() {
  return new S3Client({
    region: "auto",
    endpoint: `https://${process.env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
    credentials: {
      accessKeyId: process.env.R2_ACCESS_KEY_ID,
      secretAccessKey: process.env.R2_SECRET_ACCESS_KEY,
    },
  });
}

// ---- R2 spend cap ----
// R2 has no hard spending limit, so the cap lives here: new uploads are
// refused once the bucket's estimated storage bill reaches the cap.
// Estimate = (stored GB - free GB) x price per GB-month. Cloudflare counts
// 1 GB as 1,000,000,000 bytes. Operations fees are tiny next to storage, so
// they're ignored. Change the cap with R2_SPEND_CAP_USD in Vercel (default 3.50).
const R2_FREE_BYTES = 10 * 1e9;
const R2_USD_PER_GB_MONTH = 0.015;
const R2_CAP_USD = Number(process.env.R2_SPEND_CAP_USD) > 0 ? Number(process.env.R2_SPEND_CAP_USD) : 3.5;
const R2_CAP_BYTES = R2_FREE_BYTES + (R2_CAP_USD / R2_USD_PER_GB_MONTH) * 1e9;

let r2SizeCache = { at: 0, bytes: 0 };

async function r2BucketBytes() {
  if (Date.now() - r2SizeCache.at < 60 * 1000) return r2SizeCache.bytes;
  let bytes = 0;
  let token;
  do {
    const page = await r2Client().send(new ListObjectsV2Command({
      Bucket: process.env.R2_BUCKET_NAME, ContinuationToken: token,
    }));
    for (const o of page.Contents || []) bytes += Number(o.Size) || 0;
    token = page.IsTruncated ? page.NextContinuationToken : undefined;
  } while (token);
  r2SizeCache = { at: Date.now(), bytes };
  return bytes;
}

// Returns an error message when this upload would push storage past the
// cap, otherwise null. If the bucket can't be measured, uploads are
// allowed (a failed check shouldn't take uploads down) and it's logged.
export async function r2CapBlocks(incomingBytes) {
  try {
    const used = await r2BucketBytes();
    if (used + (Number(incomingBytes) || 0) > R2_CAP_BYTES) {
      return "Video storage is full right now, so new uploads are paused. Please contact GoalieIQ and we'll sort it out.";
    }
  } catch (error) {
    console.error("R2 cap check failed; allowing the upload:", error);
  }
  return null;
}

// Every new object lives under "<owner user id>/". game_videos rows are
// written by the browser, so a row's storage_path is only trusted when
// it can't be pointing at someone else's file. Without this, a user
// could aim their own row at another user's video and then watch,
// download, or delete it.
//
//  - Path inside the row owner's folder: trusted (nobody else can
//    upload into that folder).
//  - Anything else (older clips an admin uploaded under the admin's
//    own folder): trusted only when no other user's row references the
//    same file. Checked with the service key, since RLS would hide the
//    other rows from the caller.
export async function storagePathIsTrusted(row) {
  if (!row || typeof row.storage_path !== "string" || !row.user_id) return false;
  const path = row.storage_path;
  if (path.includes("..") || path.includes("\\") || path.startsWith("/")) return false;
  if (path.startsWith(`${row.user_id}/`)) return true;

  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) return false;
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/game_videos?select=user_id&storage_path=eq.${encodeURIComponent(path)}`,
    { headers: { apikey: key, Authorization: `Bearer ${key}` } }
  );
  if (!res.ok) return false;
  const rows = await res.json();
  return Array.isArray(rows) && rows.length > 0 && rows.every(r => r.user_id === row.user_id);
}

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// ---- Responses ----

// Log the real error server-side; send the browser a plain message
// that never carries upstream API text, keys, or table names.
export function sendServerError(res, error, message = "Something went wrong. Please try again.") {
  console.error(error);
  res.status(500).json({ error: message });
}
