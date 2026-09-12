// ============================================================
// VIDEO PIPELINE — STEP 1: INDEX
// ============================================================
// Takes a game_videos row whose file already lives in Cloudflare R2
// (uploaded via r2-start-upload.js / r2-complete-upload.js), and
// kicks off indexing on TwelveLabs. This only STARTS indexing --
// indexing a full game can take a few minutes, so this function
// returns quickly and step 2 (analyze-game-video.js) is called
// separately once indexing is done.
//
// Why TwelveLabs instead of memories.ai: same role in the pipeline
// (find and understand shot moments in a long video), but TwelveLabs
// is purpose-built for exactly this and is meaningfully cheaper
// (~$0.033-0.042/min indexing vs memories.ai's $0.05/min), plus a
// 600-minute free tier that doesn't expire -- at your current volume
// (a few 90-minute games a month) that's likely 6+ months before you
// pay anything at all.
//
// Setup required:
//   - TWELVELABS_API_KEY environment variable in Vercel. Sign up at
//     twelvelabs.io, create a key from the dashboard's API Keys page.
//   - Same R2_* and ANTHROPIC_API_KEY variables already used
//     elsewhere in this pipeline.
//
// IMPORTANT -- READ BEFORE RELYING ON THIS:
// Built from TwelveLabs' current (v1.3) published docs and code
// samples, but I don't have a TwelveLabs account to test end to end.
// Two things worth a quick manual check once you have a key:
//   1. The model name below ("pegasus1.2") -- TwelveLabs updates
//      model versions periodically; check their dashboard/docs for
//      the current recommended model name if index creation fails.
//   2. That the /tasks endpoint still accepts a video_url pointing
//      at a signed R2 URL (their newer asset-upload flow warns that
//      some cloud-storage "sharing links" aren't supported -- a
//      presigned direct-object URL like ours should be fine since
//      it points straight at the file, not a share-page, but worth
//      confirming with one real upload).
// If either has changed, this file and the matching call in
// analyze-game-video.js are the only places to touch.

import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

const SUPABASE_URL = "https://iiuqxxrrruvwvfehrzic.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ";

const TWELVELABS_HOST = "https://api.twelvelabs.io/v1.3";
const TWELVELABS_INDEX_NAME = "goalieiq-game-footage";
const TWELVELABS_MODEL = "pegasus1.2";

function r2Client() {
  return new S3Client({
    region: "auto",
    endpoint: `https://${process.env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
    credentials: {
      accessKeyId: process.env.R2_ACCESS_KEY_ID,
      secretAccessKey: process.env.R2_SECRET_ACCESS_KEY,
    },
  });
}

// --- Supabase helpers -------------------------------------------------

async function verifyAccessToken(accessToken) {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${accessToken}`,
    },
  });
  if (!res.ok) return null;
  const data = await res.json();
  return data && data.id ? data : null;
}

async function supabaseGet(table, filter, accessToken) {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/${table}?${filter}&select=*`,
    {
      headers: {
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${accessToken}`,
      },
    }
  );
  if (!res.ok) throw new Error(`Supabase GET ${table} failed: ${res.status}`);
  return res.json();
}

async function supabasePatch(table, filter, body, accessToken) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${table}?${filter}`, {
    method: "PATCH",
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      Prefer: "return=representation",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Supabase PATCH ${table} failed: ${res.status} ${errText}`);
  }
  return res.json();
}

// Signed URL so TwelveLabs (an external service) can fetch the
// video straight from R2, without R2 needing to be a public bucket.
async function getR2SignedUrl(objectKey) {
  const client = r2Client();
  return getSignedUrl(
    client,
    new GetObjectCommand({
      Bucket: process.env.R2_BUCKET_NAME,
      Key: objectKey,
    }),
    { expiresIn: 60 * 60 * 6 } // 6 hours -- generous for indexing time
  );
}

// --- TwelveLabs helpers -------------------------------------------------

async function twelveLabsJSON(path, method, body) {
  const res = await fetch(`${TWELVELABS_HOST}${path}`, {
    method,
    headers: {
      "x-api-key": process.env.TWELVELABS_API_KEY,
      "Content-Type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(
      `TwelveLabs ${path} failed: ${res.status} ${JSON.stringify(data)}`
    );
  }
  return data;
}

// Reuse one index across every uploaded game rather than creating a
// new one per video -- keeps your TwelveLabs account tidy.
async function getOrCreateIndex() {
  // Free, no-cost call.
  const listRes = await fetch(
    `${TWELVELABS_HOST}/indexes?index_name=${encodeURIComponent(
      TWELVELABS_INDEX_NAME
    )}`,
    { headers: { "x-api-key": process.env.TWELVELABS_API_KEY } }
  );
  const listData = await listRes.json().catch(() => ({}));
  const existing =
    (listData.data || []).find(
      (idx) => idx.index_name === TWELVELABS_INDEX_NAME
    ) || null;
  if (existing) return existing.id || existing._id;

  const created = await twelveLabsJSON("/indexes", "POST", {
    index_name: TWELVELABS_INDEX_NAME,
    models: [
      {
        model_name: TWELVELABS_MODEL,
        model_options: ["visual", "audio"],
      },
    ],
  });
  return created.id || created._id;
}

// Kicks off upload + indexing in one call. TwelveLabs' /tasks
// endpoint requires multipart/form-data even when using a URL
// instead of a raw file.
async function createIndexingTask(indexId, videoUrl) {
  const form = new FormData();
  form.append("index_id", indexId);
  form.append("video_url", videoUrl);

  const res = await fetch(`${TWELVELABS_HOST}/tasks`, {
    method: "POST",
    headers: { "x-api-key": process.env.TWELVELABS_API_KEY },
    body: form,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(
      `TwelveLabs /tasks failed: ${res.status} ${JSON.stringify(data)}`
    );
  }
  return data;
}

// --- handler ------------------------------------------------------------

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const { accessToken, gameVideoId } = req.body || {};
  if (!accessToken || !gameVideoId) {
    res.status(400).json({ error: "Missing accessToken or gameVideoId." });
    return;
  }

  if (
    !process.env.TWELVELABS_API_KEY ||
    !process.env.R2_ACCOUNT_ID ||
    !process.env.R2_ACCESS_KEY_ID ||
    !process.env.R2_SECRET_ACCESS_KEY ||
    !process.env.R2_BUCKET_NAME
  ) {
    res.status(503).json({
      error:
        "Video indexing isn't configured yet -- check TWELVELABS_API_KEY, R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, and R2_BUCKET_NAME in Vercel project settings.",
    });
    return;
  }

  try {
    const user = await verifyAccessToken(accessToken);
    if (!user) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }

    const rows = await supabaseGet(
      "game_videos",
      `id=eq.${encodeURIComponent(gameVideoId)}`,
      accessToken
    );
    const gameVideo = rows[0];
    if (!gameVideo) {
      res.status(404).json({ error: "game_videos row not found." });
      return;
    }

    const signedUrl = await getR2SignedUrl(gameVideo.storage_path);
    const indexId = await getOrCreateIndex();

    // Kick off indexing. This is the priced call (~$0.033-0.042/min
    // of video, 600 min/month free). Fire-and-forget from this
    // function's point of view: we store the returned task id and
    // mark status "indexing", then step 2 polls/uses it once ready.
    const task = await createIndexingTask(indexId, signedUrl);
    const taskId = task.id || task._id;

    // Column name is a holdover from the memories.ai version of this
    // pipeline -- it just holds "this video's opaque reference id
    // from whichever vendor is configured" and isn't worth a schema
    // migration to rename. It holds a TwelveLabs task id now; step 2
    // resolves the actual video_id from this once the task is ready.
    await supabasePatch(
      "game_videos",
      `id=eq.${encodeURIComponent(gameVideoId)}`,
      {
        memories_video_no: taskId,
        status: "indexing",
        updated_at: new Date().toISOString(),
      },
      accessToken
    );

    res.status(200).json({
      status: "indexing",
      taskId,
    });
  } catch (error) {
    console.error(error);
    try {
      await supabasePatch(
        "game_videos",
        `id=eq.${encodeURIComponent(gameVideoId)}`,
        {
          status: "failed",
          error_message: String(error.message || error),
          updated_at: new Date().toISOString(),
        },
        accessToken
      );
    } catch (_) {
      // best-effort -- don't mask the original error
    }
    res.status(500).json({ error: error.message || "Something went wrong." });
  }
}
