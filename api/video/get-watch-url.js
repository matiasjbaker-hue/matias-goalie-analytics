// ============================================================
// VIDEO PIPELINE — GET AN INLINE-PLAYABLE URL (WATCH, NOT DOWNLOAD)
// ============================================================
// Sibling to get-download-url.js, with two differences:
//   1. No Content-Disposition: attachment -- the browser plays this
//      inline in a <video> element instead of downloading a file.
//   2. Not admin-only. Authorization is delegated to Supabase RLS on
//      game_videos ("read own or assigned or admin game_videos") by
//      fetching the row with the caller's OWN access token. If RLS
//      returns zero rows, this 404s.
//
// R2 serves range requests on GetObject, so the browser's <video>
// element can seek within the file using this one signed URL.

import { GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import {
  verifyUser, userSelect, r2Configured, r2Client,
  storagePathIsTrusted, sendServerError,
} from "../_lib/supabase.js";

// Long enough to watch a shot, rewind, watch it again, without the URL
// expiring mid-viewing -- short enough that a leaked link isn't useful
// for long.
const WATCH_URL_EXPIRY_SECONDS = 60 * 30;

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

  if (!r2Configured()) {
    res.status(503).json({ error: "Video storage isn't configured yet." });
    return;
  }

  try {
    if (!(await verifyUser(accessToken))) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }

    const rows = await userSelect("game_videos", `id=eq.${encodeURIComponent(gameVideoId)}&select=*`, accessToken);
    const gameVideo = rows[0];

    // RLS decides whether the row is visible; the path check stops a row
    // that points into someone else's folder from unlocking their file.
    if (!gameVideo || !(await storagePathIsTrusted(gameVideo))) {
      res.status(404).json({ error: "Video not found, or you don't have access to it." });
      return;
    }

    const url = await getSignedUrl(
      r2Client(),
      new GetObjectCommand({
        Bucket: process.env.R2_BUCKET_NAME,
        Key: gameVideo.storage_path,
      }),
      { expiresIn: WATCH_URL_EXPIRY_SECONDS }
    );

    res.status(200).json({ url });
  } catch (error) {
    sendServerError(res, error, "Could not load the video.");
  }
}
