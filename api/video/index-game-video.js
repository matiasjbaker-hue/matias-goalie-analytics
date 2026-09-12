// ============================================================
// VIDEO PIPELINE — STEP 1: INDEX
// ============================================================
// Takes a game_videos row that already has a file sitting in the
// Supabase "game-footage" storage bucket, and kicks off indexing
// on memories.ai's Video Datalake. This only STARTS indexing --
// indexing a full game can take a few minutes, so this function
// returns quickly and step 2 (analyze-game-video.js) is called
// separately once indexing is done.
//
// Setup required:
//   - MEMORIES_AI_API_KEY environment variable in Vercel, from
//     your memories.ai account (console.memories.ai or similar --
//     check their current dashboard when you sign up).
//   - Same ANTHROPIC_API_KEY and Supabase project already used by
//     api/coach.js and api/game-report.js.
//
// IMPORTANT -- READ BEFORE DEPLOYING:
// memories.ai's API is mid-migration: their older v1 API
// (api.memories.ai/serve/api/v1) is documented as sunset, and the
// new "Video Datalake" v2 API (api.memories.ai/datalake/v1) is
// what they're pushing developers toward. The collection/video
// request shapes below are built from their published docs and
// examples, but I don't have a memories.ai account to test end to
// end. Before relying on this in production: sign up, grab your
// key, and run ONE request by hand (curl or Postman) against
// MEMORIES_AI_HOST + "/collections" to confirm the exact field
// names still match what's below -- their dashboard will show you
// the current request shape for your account. If a field name has
// changed, this is the only file you need to touch.

const SUPABASE_URL = "https://iiuqxxrrruvwvfehrzic.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ";

const MEMORIES_AI_HOST = "https://api.memories.ai/datalake/v1";
const MEMORIES_AI_COLLECTION_NAME = "goalieiq-game-footage";

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

// Signed URL so memories.ai (an external service) can fetch the
// private "game-footage" object without the bucket being public.
async function getSignedStorageUrl(storagePath, accessToken) {
  const res = await fetch(
    `${SUPABASE_URL}/storage/v1/object/sign/game-footage/${storagePath}`,
    {
      method: "POST",
      headers: {
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      // Long expiry -- indexing a full game can take a while and we
      // don't want the URL to die mid-index.
      body: JSON.stringify({ expiresIn: 60 * 60 * 6 }),
    }
  );
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Signed URL failed: ${res.status} ${errText}`);
  }
  const data = await res.json();
  return `${SUPABASE_URL}/storage/v1${data.signedURL}`;
}

// --- memories.ai helpers ----------------------------------------------

async function memoriesAI(path, body) {
  const res = await fetch(`${MEMORIES_AI_HOST}${path}`, {
    method: "POST",
    headers: {
      Authorization: process.env.MEMORIES_AI_API_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(
      `memories.ai ${path} failed: ${res.status} ${JSON.stringify(data)}`
    );
  }
  return data;
}

// Reuse one collection across every uploaded game rather than
// creating a new one per video -- keeps your memories.ai account
// tidy and makes cross-game search possible later if you want it.
async function getOrCreateCollection() {
  // Free, no-cost call -- see pricing table, GET /collections is free.
  const listRes = await fetch(
    `${MEMORIES_AI_HOST}/collections?name=${encodeURIComponent(
      MEMORIES_AI_COLLECTION_NAME
    )}`,
    { headers: { Authorization: process.env.MEMORIES_AI_API_KEY } }
  );
  const listData = await listRes.json().catch(() => ({}));
  const existing =
    (listData.data || listData.collections || []).find(
      (c) => c.name === MEMORIES_AI_COLLECTION_NAME
    ) || null;
  if (existing) return existing.id;

  const created = await memoriesAI("/collections", {
    name: MEMORIES_AI_COLLECTION_NAME,
  });
  return created.id;
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

  if (!process.env.MEMORIES_AI_API_KEY) {
    res.status(503).json({
      error:
        "Video indexing isn't configured yet -- add MEMORIES_AI_API_KEY in Vercel project settings.",
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
    const signedUrl = await getSignedStorageUrl(
      gameVideo.storage_path,
      accessToken
    );
    const collectionId = await getOrCreateCollection();

    // Kick off indexing. This is the priced call ($0.05/min of video --
    // see memories.ai pricing). Fire-and-forget from this function's
    // point of view: we store the returned video id and mark status
    // "indexing", then step 2 checks/uses it once ready.
    const indexResult = await memoriesAI("/videos", {
      collection_id: collectionId,
      source_url: signedUrl,
    });

    const memoriesVideoId =
      indexResult.id || indexResult.video_id || indexResult.videoNo || null;

    await supabasePatch(
      "game_videos",
      `id=eq.${encodeURIComponent(gameVideoId)}`,
      {
        memories_video_no: memoriesVideoId,
        status: "indexing",
        updated_at: new Date().toISOString(),
      },
      accessToken
    );

    res.status(200).json({
      status: "indexing",
      memoriesVideoId,
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
