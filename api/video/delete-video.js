// ============================================================
// VIDEO PIPELINE — DELETE AN UPLOADED VIDEO
// ============================================================
// Deletes both the actual video file in R2 and its game_videos row.
// Deleting the row cascades to any shot_drafts tied to it (already
// set up via ON DELETE CASCADE), so there's nothing extra to clean
// up on that side.
//
// Admin-only, same as everything else in the Video Review tab. RLS
// on game_videos also allows the video's own owner to delete it
// (matches "delete own or admin game_videos" policy), so this
// endpoint checks for either rather than admin-only, in case this
// ever gets exposed on the customer-facing side too.

import { S3Client, DeleteObjectCommand } from "@aws-sdk/client-s3";

const SUPABASE_URL = "https://iiuqxxrrruvwvfehrzic.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ";

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

// Uses the caller's own access token, not a service-role key -- RLS
// on game_videos ("delete own or admin") decides whether this is
// actually allowed, same as every other write in this pipeline.
async function supabaseDelete(table, filter, accessToken) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${table}?${filter}`, {
    method: "DELETE",
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${accessToken}`,
      Prefer: "return=representation",
    },
  });
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Supabase DELETE ${table} failed: ${res.status} ${errText}`);
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
      // Already gone, or RLS hid it -- either way, nothing left to do.
      res.status(404).json({ error: "Video not found (or you don't have permission to delete it)." });
      return;
    }

    // Delete the actual file in R2 first. If R2 credentials aren't
    // configured, skip this rather than block the DB cleanup --
    // better to remove the record and leave an orphaned file than
    // get stuck unable to delete anything.
    if (
      process.env.R2_ACCOUNT_ID &&
      process.env.R2_ACCESS_KEY_ID &&
      process.env.R2_SECRET_ACCESS_KEY &&
      process.env.R2_BUCKET_NAME
    ) {
      try {
        const client = r2Client();
        await client.send(
          new DeleteObjectCommand({
            Bucket: process.env.R2_BUCKET_NAME,
            Key: gameVideo.storage_path,
          })
        );
      } catch (r2Error) {
        console.error("R2 delete failed, continuing with DB cleanup:", r2Error);
      }
    }

    // Deleting the row cascades to shot_drafts automatically.
    const deletedRows = await supabaseDelete(
      "game_videos",
      `id=eq.${encodeURIComponent(gameVideoId)}`,
      accessToken
    );

    if (!deletedRows || !deletedRows.length) {
      res.status(403).json({
        error: "Nothing was deleted -- you may not have permission to delete this video.",
      });
      return;
    }

    res.status(200).json({ deleted: true });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: error.message || "Something went wrong." });
  }
}
