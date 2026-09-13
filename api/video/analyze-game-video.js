// ============================================================
// VIDEO PIPELINE — STEP 2: FIND SHOTS
// ============================================================
// Call this after index-game-video.js has created a TwelveLabs
// analysis task. This function just CHECKS the task's status --
// if it's not ready yet, it returns a 409 and the admin can click
// "Find shots" again in a bit. Once ready, it writes one shot_draft
// per moment TwelveLabs found, with its timestamp and plain-language
// description -- and nothing else filled in.
//
// By design, this does NOT try to fill in location/shot type/
// outcome/etc automatically. Nik reads TwelveLabs' description (and
// watches the clip at that timestamp) and fills in every stat
// himself in the Video Review tab. This removes the Claude
// structured-extraction step entirely -- one less vendor, one less
// billing dependency, and matches the actual ask: break the game
// into shot moments so a human can do the stats.
//
// This whole function is admin-only (enforced both here and by RLS
// on shot_drafts) -- customers never trigger this, and nothing it
// writes ever touches the real "Shots" table or fires the xG
// trigger. It only ever writes to shot_drafts, which the admin
// reviews and confirms one at a time in the Video Review tab.

const SUPABASE_URL = "https://iiuqxxrrruvwvfehrzic.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ";
const TWELVELABS_HOST = "https://api.twelvelabs.io/v1.3";

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
    description: m.description || m.caption || "",
  }));
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

  if (!process.env.TWELVELABS_API_KEY) {
    res.status(503).json({
      error:
        "Video analysis isn't configured yet -- check TWELVELABS_API_KEY in Vercel project settings.",
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
        error: "This video hasn't been submitted for analysis yet.",
      });
      return;
    }

    const task = await getAnalysisTask(gameVideo.memories_video_no);

    if (task.status === "failed") {
      res.status(500).json({
        error: `TwelveLabs analysis failed for this video. Raw task: ${JSON.stringify(task)}`,
      });
      return;
    }

    if (task.status !== "ready") {
      res.status(409).json({
        error: `Still processing on TwelveLabs (status: ${task.status || "unknown"}). Try again in a bit.`,
      });
      return;
    }

    const moments = parseShotListFromTask(task);

    const drafted = [];
    for (const moment of moments) {
      const draftRow = {
        game_video_id: gameVideo.id,
        game_id: gameVideo.game_id,
        user_id: gameVideo.user_id,
        start_seconds: moment.start,
        end_seconds: moment.end,
        ai_description: moment.description,
        // Every stat field is left blank on purpose -- Nik fills
        // these in himself after reading the description and/or
        // watching the clip at this timestamp.
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
