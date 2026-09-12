// ============================================================
// VIDEO PIPELINE — STEP 1: START ANALYSIS TASK
// ============================================================
// Creates an asynchronous TwelveLabs analysis task for this video
// and returns immediately -- this call itself is fast (just
// registers the job), regardless of how long the video is. Step 2
// (analyze-game-video.js) polls for the result separately.
//
// Why async instead of the synchronous /analyze call this pipeline
// used briefly: a single request analyzing a whole video can run
// well past a minute, and Vercel's Hobby plan hard-caps functions at
// 60 seconds no matter what maxDuration says in code (that only
// takes effect on paid plans). The async pattern -- create a task,
// then check on it separately -- means no single request has to
// stay open for the whole analysis, so it works regardless of plan.
// TwelveLabs' own docs recommend this same endpoint for anything
// over quick clips.
//
// Setup required:
//   - TWELVELABS_API_KEY environment variable in Vercel.
//   - Same R2_* and ANTHROPIC_API_KEY variables already used
//     elsewhere in this pipeline.
//
// IMPORTANT -- READ BEFORE RELYING ON THIS:
// Built from TwelveLabs' current (v1.3) docs for the async analysis
// endpoint, not tested against a live account yet. If task creation
// fails, check the raw error message this throws -- it includes
// TwelveLabs' full response body, which will name the actual
// problem (e.g. a field name or the video URL not being reachable).

import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

const SUPABASE_URL = "https://iiuqxxrrruvwvfevfehrzic.supabase.co".replace("iiuqxxrrruvwvfevfehrzic","iiuqxxrrruvwvfehrzic");
const SUPABASE_ANON_KEY = "sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ";
const TWELVELABS_HOST = "https://api.twelvelabs.io/v1.3";

// Shared with analyze-game-video.js conceptually -- this is what
// TwelveLabs is asked to produce once the task completes.
export const SHOT_LIST_PROMPT = `List every shot attempt on goal in this hockey video. For each one, give the approximate start time in seconds into the video, and a plain-language description of what happens (who has the puck, where they shoot from, what happens right before and after -- rebounds, screens, deflections, breakaways, whether it's a goal or a save).

Respond with ONLY a JSON array, no markdown fences, no preamble, in this exact shape:
[
  { "start_seconds": 42, "description": "..." },
  { "start_seconds": 130, "description": "..." }
]
If you find no clear shot attempts, respond with an empty array: []`;

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

async function getR2SignedUrl(objectKey) {
  const client = r2Client();
  return getSignedUrl(
    client,
    new GetObjectCommand({
      Bucket: process.env.R2_BUCKET_NAME,
      Key: objectKey,
    }),
    // Generous expiry -- TwelveLabs fetches the video asynchronously
    // on its own schedule, not necessarily the instant this call is
    // made.
    { expiresIn: 60 * 60 * 6 }
  );
}

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

async function createAnalysisTask(videoUrl) {
  const res = await fetch(`${TWELVELABS_HOST}/analyze/tasks`, {
    method: "POST",
    headers: {
      "x-api-key": process.env.TWELVELABS_API_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model_name: "pegasus1.5",
      analysis_mode: "general",
      video: { type: "url", url: videoUrl },
      prompt: SHOT_LIST_PROMPT,
      temperature: 0,
    }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(
      `TwelveLabs /analyze/tasks failed: ${res.status} ${JSON.stringify(data)}`
    );
  }
  return data;
}

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
    const task = await createAnalysisTask(signedUrl);
    const taskId = task.id || task._id || task.task_id;

    if (!taskId) {
      throw new Error(
        `TwelveLabs task creation returned no recognizable id. Raw response: ${JSON.stringify(task)}`
      );
    }

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

    res.status(200).json({ status: "indexing", taskId });
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
