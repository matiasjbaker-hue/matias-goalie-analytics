// ============================================================
// VIDEO PIPELINE — STEP 2: FIND SHOTS + DRAFT STATS
// ============================================================
// This is now the ONLY step that talks to TwelveLabs. Pegasus 1.5
// analyzes a video directly from a URL in one synchronous call and
// returns text in the response -- no index, no upload task, no
// polling. (See index-game-video.js for why the earlier index/task
// step went away.)
//
// Division of labor, on purpose:
//   1. TwelveLabs (Pegasus 1.5) watches the whole video and, in ONE
//      call, returns a list of shot-on-goal moments with timestamps
//      and a plain-language description of each.
//   2. Claude turns each plain-language description into the exact
//      structured fields your Shots table needs, and is told
//      explicitly to say "unclear" rather than guess. This part is
//      UNCHANGED from every earlier version of this pipeline -- same
//      model/API key your app already uses in api/coach.js and
//      api/game-report.js.
//
// This whole function is admin-only (enforced both here and by RLS
// on shot_drafts) -- customers never trigger this, and nothing it
// writes ever touches the real "Shots" table or fires the xG
// trigger. It only ever writes to shot_drafts, which the admin
// reviews and confirms one at a time in the Video Review tab.
//
// IMPORTANT -- READ BEFORE RELYING ON THIS:
// Built from TwelveLabs' current docs/release notes (Pegasus 1.5,
// general analysis mode), not tested against a live account.
// Specifically unverified: the exact field name holding the
// response text (guessed as `data`, matching their older API's
// convention) and whether a ~90-minute synchronous call reliably
// finishes within Vercel's function time limit. If a full game
// times out even with the extended maxDuration below, the fix is
// to switch this one call to TwelveLabs' asynchronous analyze-task
// endpoint instead -- everything downstream (Claude extraction,
// shot_drafts) is unaffected either way.

// Vercel-specific: request the longest execution window your plan
// allows, since this makes one long-running call per analysis.
export const config = {
  maxDuration: 300, // seconds -- Vercel Pro's max; lower on Hobby
};

import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

const SUPABASE_URL = "https://iiuqxxrrruvwvfehrzic.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ";
const TWELVELABS_HOST = "https://api.twelvelabs.io/v1.3";
const CLAUDE_MODEL = "claude-sonnet-5";

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
    { expiresIn: 60 * 30 } // 30 min -- only needs to last one analyze call
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

// This whole step is admin-only, by design: customers never see
// drafted shots or timestamps, only Nik reviewing/editing them.
// Row Level Security on shot_drafts already enforces this at the
// database level (see the "admin ... shot_drafts" policies) -- this
// check just gives a clear error instead of a confusing RLS failure.
async function isAdminUser(userId, accessToken) {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/profiles?select=role&id=eq.${encodeURIComponent(userId)}`,
    {
      headers: {
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${accessToken}`,
      },
    }
  );
  if (!res.ok) return false;
  const rows = await res.json();
  return rows[0] && rows[0].role === "admin";
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

async function supabasePost(table, body, accessToken) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${table}`, {
    method: "POST",
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
    throw new Error(`Supabase POST ${table} failed: ${res.status} ${errText}`);
  }
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

// --- TwelveLabs: one synchronous call for the whole video --------------

const SHOT_LIST_PROMPT = `List every shot attempt on goal in this hockey video. For each one, give the approximate start time in seconds into the video, and a plain-language description of what happens (who has the puck, where they shoot from, what happens right before and after -- rebounds, screens, deflections, breakaways, whether it's a goal or a save).

Respond with ONLY a JSON array, no markdown fences, no preamble, in this exact shape:
[
  { "start_seconds": 42, "description": "..." },
  { "start_seconds": 130, "description": "..." }
]
If you find no clear shot attempts, respond with an empty array: []`;

async function getShotListFromTwelveLabs(videoUrl) {
  const res = await fetch(`${TWELVELABS_HOST}/analyze`, {
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
      `TwelveLabs /analyze failed: ${res.status} ${JSON.stringify(data)}`
    );
  }

  // VERIFY: adjust this if your account's response wraps the text
  // under a different field name.
  const text = data.data || data.text || data.output_text || "";

  if(!text){
    // None of the guessed field names matched -- rather than fail
    // with an opaque "empty JSON" error, show the actual response
    // shape so the real field name can be read directly instead of
    // guessed a fourth time.
    throw new Error(
      `TwelveLabs /analyze returned no recognizable text field. Raw response: ${JSON.stringify(data)}`
    );
  }

  const cleaned = text.replace(/```json|```/g, "").trim();

  let parsed;
  try {
    parsed = JSON.parse(cleaned);
  } catch (e) {
    throw new Error(
      `Could not parse TwelveLabs' shot list as JSON: ${e.message}`
    );
  }

  if (!Array.isArray(parsed)) return [];

  return parsed.map((m) => ({
    start: m.start_seconds ?? m.start ?? 0,
    end: (m.start_seconds ?? m.start ?? 0) + 5, // short default window
    caption: m.description || m.caption || "",
  }));
}

// --- Claude: turn one moment's description into structured stats ------
// (unchanged from every earlier version of this pipeline -- same
// model, same key, same prompt)

const SHOT_EXTRACTION_SYSTEM_PROMPT = `You convert a short description of a hockey shot-on-goal moment into structured data for a goalie analytics app. You are given a plain-language description generated by a separate video-indexing system -- you are not watching the video yourself, only reading its description.

Respond with ONLY a JSON object, no markdown fences, no preamble, matching exactly this shape:

{
  "outcome": "goal" | "save" | "unclear",
  "distance": <number in feet, or null if unclear>,
  "location": "Crease" | "Slot" | "Circle" | "Point" | "Perimeter" | "unclear",
  "shot_type": "wrist shot" | "slap shot" | "backhand" | "one-timer" | "unclear",
  "rush": true | false | "unclear",
  "rebound": true | false | "unclear",
  "screened": true | false | "unclear",
  "breakaway": true | false | "unclear",
  "cross_ice": true | false | "unclear",
  "deflection": true | false | "unclear",
  "uncertain_fields": "<comma-separated list of field names you marked unclear, or empty string if none>"
}

Critical rule: if the description does not clearly support a field, use "unclear" (or null for distance) -- NEVER guess a specific value you can't actually support from the description. A false "unclear" costs a coach a few seconds to check by eye; a confident wrong guess costs their trust in the whole system.`;

async function extractShotFromMoment(moment) {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": process.env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: CLAUDE_MODEL,
      max_tokens: 400,
      system: SHOT_EXTRACTION_SYSTEM_PROMPT,
      messages: [
        {
          role: "user",
          content: `Moment description: ${moment.caption || "(no description available)"}`,
        },
      ],
    }),
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Claude extraction failed: ${res.status} ${errText}`);
  }

  const data = await res.json();
  const text = (data.content || [])
    .filter((b) => b.type === "text")
    .map((b) => b.text)
    .join("\n");

  const cleaned = text.replace(/```json|```/g, "").trim();
  return JSON.parse(cleaned);
}

function toBoolOrNull(v) {
  if (v === true || v === false) return v;
  return null; // "unclear" -> null, left for the coach to fill in
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
    !process.env.ANTHROPIC_API_KEY ||
    !process.env.R2_ACCOUNT_ID ||
    !process.env.R2_ACCESS_KEY_ID ||
    !process.env.R2_SECRET_ACCESS_KEY ||
    !process.env.R2_BUCKET_NAME
  ) {
    res.status(503).json({
      error:
        "Video analysis isn't fully configured -- check TWELVELABS_API_KEY, ANTHROPIC_API_KEY, and the R2_* variables in Vercel project settings.",
    });
    return;
  }

  try {
    const user = await verifyAccessToken(accessToken);
    if (!user) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }

    const callerIsAdmin = await isAdminUser(user.id, accessToken);
    if (!callerIsAdmin) {
      res.status(403).json({
        error: "Only an admin account can run shot analysis on a video.",
      });
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
    const moments = await getShotListFromTwelveLabs(signedUrl);

    const drafted = [];
    for (const moment of moments) {
      let extracted;
      try {
        extracted = await extractShotFromMoment(moment);
      } catch (e) {
        console.error("Extraction failed for one moment, skipping:", e);
        continue;
      }

      const draftRow = {
        game_video_id: gameVideo.id,
        game_id: gameVideo.game_id,
        user_id: gameVideo.user_id,
        start_seconds: moment.start,
        end_seconds: moment.end,
        outcome: extracted.outcome === "unclear" ? null : extracted.outcome,
        distance: extracted.distance ?? null,
        location: extracted.location === "unclear" ? null : extracted.location,
        shot_type:
          extracted.shot_type === "unclear" ? null : extracted.shot_type,
        rush: toBoolOrNull(extracted.rush),
        rebound: toBoolOrNull(extracted.rebound),
        screened: toBoolOrNull(extracted.screened),
        breakaway: toBoolOrNull(extracted.breakaway),
        cross_ice: toBoolOrNull(extracted.cross_ice),
        deflection: toBoolOrNull(extracted.deflection),
        uncertain_fields: extracted.uncertain_fields || "",
        status: "pending",
      };

      const inserted = await supabasePost("shot_drafts", draftRow, accessToken);
      drafted.push(inserted[0]);
    }

    await supabasePatch(
      "game_videos",
      `id=eq.${encodeURIComponent(gameVideoId)}`,
      { status: "analyzed", updated_at: new Date().toISOString() },
      accessToken
    );

    res.status(200).json({
      status: "analyzed",
      draftCount: drafted.length,
      drafts: drafted,
    });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: error.message || "Something went wrong." });
  }
}
