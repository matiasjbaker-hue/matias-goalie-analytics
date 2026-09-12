// ============================================================
// VIDEO PIPELINE — STEP 1: MARK READY FOR ANALYSIS
// ============================================================
// Historical note: earlier versions of this pipeline (memories.ai,
// then TwelveLabs with the older Pegasus 1.2) needed a real
// "indexing" step here -- upload the video into a persistent index
// and wait for it to finish before it could be analyzed.
//
// TwelveLabs' current model, Pegasus 1.5, doesn't work that way: it
// analyzes a video directly from a URL in one synchronous call, with
// no pre-indexing at all (confirmed by TwelveLabs' own API error
// message when the old pegasus1.2 model name stopped working: "no
// index [needed]; pegasus1.5 analyzes video directly on POST
// /analyze"). So this step no longer has any real work to do -- it
// just marks the video ready, and analyze-game-video.js does
// everything else in one call.
//
// Kept as its own file/step (rather than deleting it and folding
// everything into upload) so the admin-facing status flow
// (uploaded -> indexed -> analyzed) and the "Find shots" button in
// the Video Review tab don't need to change.

const SUPABASE_URL = "https://iiuqxxrrruvwvfehrzic.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ";

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

    await supabasePatch(
      "game_videos",
      `id=eq.${encodeURIComponent(gameVideoId)}`,
      {
        status: "indexed",
        updated_at: new Date().toISOString(),
      },
      accessToken
    );

    res.status(200).json({ status: "indexed" });
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
