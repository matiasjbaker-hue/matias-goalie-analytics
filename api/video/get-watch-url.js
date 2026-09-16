// ============================================================
// VIDEO PIPELINE — GET AN INLINE-PLAYABLE URL (WATCH, NOT DOWNLOAD)
// ============================================================
// Sibling to get-download-url.js, with two differences:
//   1. No Content-Disposition: attachment -- the browser plays this
//      inline in a <video> element instead of downloading a file.
//   2. Not admin-only. Authorization is delegated entirely to
//      Supabase RLS on game_videos ("read own or assigned or admin
//      game_videos": user_id = auth.uid() OR is_admin() OR
//      is_my_goalie(user_id)) by fetching the row with the caller's
//      OWN access token rather than a service/admin credential. If
//      RLS returns zero rows, this 404s -- there is no separate
//      authorization check to keep in sync with that policy.
//
// R2 (S3-compatible) serves range requests on GetObject, so the
// browser's own <video> element can seek within the file using this
// one signed URL -- no per-shot clip extraction needed. See the
// GoalieIQ video architecture assessment (shot log / Phase 4) for
// why this is Option B (store source + timestamps, play dynamically)
// rather than pre-generating a clip per shot.

import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

const SUPABASE_URL = "https://iiuqxxrrruvwvfehrzic.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ";

// Long enough to watch a shot, rewind, watch it again, without the
// URL expiring mid-viewing -- short enough that a leaked link isn't
// useful for long.
const WATCH_URL_EXPIRY_SECONDS = 60 * 30;

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
    !process.env.R2_ACCOUNT_ID ||
    !process.env.R2_ACCESS_KEY_ID ||
    !process.env.R2_SECRET_ACCESS_KEY ||
    !process.env.R2_BUCKET_NAME
  ) {
    res.status(503).json({ error: "Video storage isn't configured yet." });
    return;
  }

  try {
    // Fetched with the CALLER's own token -- RLS on game_videos is
    // what actually decides whether this row (and therefore the
    // video) is visible to them. No separate admin/ownership check
    // here on purpose: this file should never drift out of sync
    // with the policy that already exists on the table.
    const rows = await supabaseGet(
      "game_videos",
      `id=eq.${encodeURIComponent(gameVideoId)}`,
      accessToken
    );

    const gameVideo = rows[0];
    if (!gameVideo) {
      res.status(404).json({
        error: "Video not found, or you don't have access to it.",
      });
      return;
    }

    const client = r2Client();
    const url = await getSignedUrl(
      client,
      new GetObjectCommand({
        Bucket: process.env.R2_BUCKET_NAME,
        Key: gameVideo.storage_path,
        // Deliberately no ResponseContentDisposition here -- this is
        // the one substantive difference from get-download-url.js.
        // Omitting it lets the browser play the file inline instead
        // of forcing a download.
      }),
      { expiresIn: WATCH_URL_EXPIRY_SECONDS }
    );

    res.status(200).json({ url });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: error.message || "Something went wrong." });
  }
}
