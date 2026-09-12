// ============================================================
// VIDEO PIPELINE — STEP 2: FIND SHOTS + DRAFT STATS
// ============================================================
// Call this once index-game-video.js's TwelveLabs task has finished
// indexing -- try a minute or two after upload; a 409 "still
// indexing" response just means try again later.
//
// Division of labor, on purpose:
//   1. TwelveLabs (Pegasus model) watches the whole video and, in
//      ONE call, returns a list of shot-on-goal moments with
//      timestamps and a plain-language description of each -- this
//      is the same "find needles in a long video" role memories.ai
//      played, just from a different vendor.
//   2. Claude turns each plain-language description into the exact
//      structured fields your Shots table needs, and is told
//      explicitly to say "unclear" rather than guess. This part is
//      UNCHANGED from the memories.ai version -- same model/API key
//      your app already uses in api/coach.js and api/game-report.js,
//      so it has a known, tested request/response shape. Only step
//      1's TwelveLabs field names carry any real uncertainty (see
//      the note in index-game-video.js).
//
// This whole function is admin-only (enforced both here and by RLS
// on shot_drafts) -- customers never trigger this, and nothing it
// writes ever touches the real "Shots" table or fires the xG
// trigger. It only ever writes to shot_drafts, which the admin
// reviews and confirms one at a time in the Video Review tab.

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

// --- TwelveLabs: check indexing status, then ask for a shot list ------
//
// VERIFY WHEN YOU HAVE A KEY: this is built from TwelveLabs' current
// docs/code samples, not tested against a live account. The task
// status/video_id shape (task.status, task.video_id) is well
// documented and should be solid. The /analyze request/response
// shape below is closer to their frontier -- if the response comes
// back differently, this function (and only this function) needs
// adjusting; the Claude-extraction step downstream is unaffected.

async function getTaskStatus(taskId) {
  const res = await fetch(`${TWELVELABS_HOST}/tasks/${taskId}`, {
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

const SHOT_LIST_PROMPT = `List every shot attempt on goal in this hockey video. For each one, give the approximate start time in seconds into the video, and a plain-language description of what happens (who has the puck, where they shoot from, what happens right before and after -- rebounds, screens, deflections, breakaways, whether it's a goal or a save).

Respond with ONLY a JSON array, no markdown fences, no preamble, in this exact shape:
[
  { "start_seconds": 42, "description": "..." },
  { "start_seconds": 130, "description": "..." }
]
If you find no clear shot attempts, respond with an empty array: []`;

async function getShotListFromTwelveLabs(videoId) {
  const res = await fetch(`${TWELVELABS_HOST}/analyze`, {
    method: "POST",
    headers: {
      "x-api-key": process.env.TWELVELABS_API_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      video_id: videoId,
      prompt: SHOT_LIST_PROMPT,
    }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(
      `TwelveLabs /analyze failed: ${res.status} ${JSON.stringify(data)}`
    );
  }

  // VERIFY: TwelveLabs' analyze response field is typically `data`
  // (a text string) -- adjust here if your account's response wraps
  // it differently.
  const text = data.data || data.text || "";
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
// (unchanged from the memories.ai version -- same model, same key,
// same prompt)

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
      res.status(404).json({ error: "game_videos row not found." });
      return;
    }
    if (!gameVideo.memories_video_no) {
      res.status(409).json({
        error: "This video hasn't been submitted for indexing yet.",
      });
      return;
    }

    // memories_video_no holds a TwelveLabs task id (see the note in
    // index-game-video.js on why the column is still named that).
    const task = await getTaskStatus(gameVideo.memories_video_no);

    if (task.status !== "ready") {
      res.status(409).json({
        error: `Still indexing on TwelveLabs (status: ${task.status || "unknown"}). Try again shortly.`,
      });
      return;
    }

    const videoId = task.video_id;
    if (!videoId) {
      res.status(500).json({
        error: "TwelveLabs task is ready but returned no video_id.",
      });
      return;
    }

    const moments = await getShotListFromTwelveLabs(videoId);

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
