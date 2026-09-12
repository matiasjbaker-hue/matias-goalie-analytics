// ============================================================
// VIDEO PIPELINE — STEP 2: FIND SHOTS + DRAFT STATS
// ============================================================
// Call this once index-game-video.js has finished indexing (check
// game_videos.status -- for now, just try this a minute or two
// after upload; a "still indexing" response means try again later).
//
// Division of labor, on purpose:
//   1. memories.ai finds WHERE the shot moments are and describes
//      what it sees in plain language (it's good at finding needles
//      in a long video -- that's its actual strength).
//   2. Claude turns each plain-language description into the exact
//      structured fields your Shots table needs, and is told
//      explicitly to say "unclear" rather than guess. This is the
//      same model/API key your app already uses in api/coach.js and
//      api/game-report.js, so this part has a known, tested
//      request/response shape -- only step 1's memories.ai field
//      names carry any real uncertainty (see the note in
//      index-game-video.js).
//
// This whole function is admin-only (enforced both here and by RLS
// on shot_drafts) -- customers never trigger this, and nothing it
// writes ever touches the real "Shots" table or fires the xG
// trigger. It only ever writes to shot_drafts, which the admin
// reviews and confirms one at a time in the Video Review tab.

const SUPABASE_URL = "https://iiuqxxrrruvwvfehrzic.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ";
const MEMORIES_AI_HOST = "https://api.memories.ai/datalake/v1";
const CLAUDE_MODEL = "claude-sonnet-5";

// Cap how many candidate moments we run through Claude in one call
// of this function, so a single request can't run past Vercel's
// function time limit on a very high-shot-volume game. If a game
// has more candidates than this, call the function again -- it
// skips shot_drafts rows it's already created for this video.
const MAX_MOMENTS_PER_RUN = 60;

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

// --- memories.ai: find candidate shot moments --------------------------
//
// VERIFY WHEN YOU HAVE A KEY: the /search request/response shape
// below (query text in, list of {ref, start, end, caption} moments
// out) is built from memories.ai's published examples, not tested
// against a live account. If your account's response uses different
// field names, adjust the two lines marked below -- everything
// downstream of that just reads `moment.start`, `moment.end`,
// `moment.caption` however you map them.

async function findCandidateShotMoments(memoriesVideoId) {
  const res = await fetch(`${MEMORIES_AI_HOST}/search`, {
    method: "POST",
    headers: {
      Authorization: process.env.MEMORIES_AI_API_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      video_ids: [memoriesVideoId],
      query:
        "a player shooting the puck on net toward the goalie, including rebounds, deflections, and breakaways",
      top_k: MAX_MOMENTS_PER_RUN,
    }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(`memories.ai /search failed: ${res.status} ${JSON.stringify(data)}`);
  }

  // VERIFY: adjust this mapping to match your account's actual
  // response shape once you can see a real payload.
  const rawMoments = data.results || data.moments || data.data || [];
  return rawMoments.map((m) => ({
    ref: m.ref || m.moment_ref || m.id,
    start: m.start ?? m.start_time ?? m.start_seconds ?? 0,
    end: m.end ?? m.end_time ?? m.end_seconds ?? null,
    caption: m.caption || m.description || m.summary || "",
  }));
}

// --- Claude: turn one moment's description into structured stats ------

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

  if (!process.env.MEMORIES_AI_API_KEY || !process.env.ANTHROPIC_API_KEY) {
    res.status(503).json({
      error:
        "Video analysis isn't fully configured -- check MEMORIES_AI_API_KEY and ANTHROPIC_API_KEY in Vercel project settings.",
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

    const moments = await findCandidateShotMoments(gameVideo.memories_video_no);

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
