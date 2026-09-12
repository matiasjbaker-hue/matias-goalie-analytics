// ============================================================
// VIDEO PIPELINE — STEP 2: FIND SHOTS + DRAFT STATS
// ============================================================
// Call this after index-game-video.js has created a TwelveLabs
// analysis task. This function just CHECKS the task's status --
// if it's not ready yet, it returns a 409 and the admin can click
// "Find shots" again in a bit. Once ready, it reads the result,
// runs each moment through Claude for structured extraction, and
// writes shot_drafts.
//
// Division of labor, on purpose:
//   1. TwelveLabs (Pegasus 1.5, async analysis) watches the whole
//      video and returns a list of shot-on-goal moments with
//      timestamps and a plain-language description of each.
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
// Built from TwelveLabs' current async-analysis docs, not tested
// against a live account yet. The one detail most likely to need a
// tweak: where the finished result text lives on the task object.
// Their own sample code reads it as task.result.data (nested, not a
// flat top-level field) -- that's what's used below, with a couple
// fallback field names checked too. If a "no recognizable text
// field" error comes back, it'll include the raw task object so the
// real path can be read directly.

const SUPABASE_URL = "https://iiuqxxrrruvwvfehrzic.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ";
const TWELVELABS_HOST = "https://api.twelvelabs.io/v1.3";
const CLAUDE_MODEL = "claude-sonnet-5";

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

// --- TwelveLabs: check the async task, pull the result -----------------

async function getAnalysisTask(taskId) {
  const res = await fetch(`${TWELVELABS_HOST}/analyze/tasks/${taskId}`, {
    headers: { "x-api-key": process.env.TWELVELABS_API_KEY },
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(
      `TwelveLabs task status check failed: ${res.status} ${JSON.stringify(data)}`
    );
  }
  return data;
}

function parseShotListFromTask(task) {
  // VERIFY: TwelveLabs' own sample code reads this as task.result.data
  // (nested). A couple of flatter fallbacks are checked too in case
  // your account's response shape differs.
  const text =
    (task.result && task.result.data) ||
    task.data ||
    task.output_text ||
    "";

  if (!text) {
    throw new Error(
      `TwelveLabs task is ready but has no recognizable result text. Raw task: ${JSON.stringify(task)}`
    );
  }

  const cleaned = text.replace(/```json|```/g, "").trim();

  let parsed;
  try {
    parsed = JSON.parse(cleaned);
  } catch (e) {
    throw new Error(
      `Could not parse TwelveLabs' shot list as JSON: ${e.message}. Raw text: ${text}`
    );
  }

  // Handle the model wrapping the array under a key (e.g. {"shots":[...]})
  // instead of returning a bare array, despite the prompt asking for one.
  if (!Array.isArray(parsed) && parsed && typeof parsed === "object") {
    const arrayField = Object.values(parsed).find((v) => Array.isArray(v));
    if (arrayField) parsed = arrayField;
  }

  if (!Array.isArray(parsed)) {
    throw new Error(
      `TwelveLabs' shot list parsed as JSON but wasn't an array (or an object wrapping one). Raw text: ${text}`
    );
  }

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

  if (!process.env.TWELVELABS_API_KEY || !process.env.ANTHROPIC_API_KEY) {
    res.status(503).json({
      error:
        "Video analysis isn't fully configured -- check TWELVELABS_API_KEY and ANTHROPIC_API_KEY in Vercel project settings.",
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
