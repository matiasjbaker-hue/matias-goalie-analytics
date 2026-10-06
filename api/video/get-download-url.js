// ============================================================
// VIDEO PIPELINE — GET A DOWNLOAD LINK FOR THE ACTUAL FILE
// ============================================================
// Returns a short-lived signed URL pointing straight at the video file
// in R2, with a content-disposition header that forces a download.
// Admin-only, same pattern as the rest of Video Review.

import { GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import {
  verifyUser, callerRole, userSelect, r2Configured, r2Client,
  storagePathIsTrusted, sendServerError,
} from "../_lib/supabase.js";

// Keep only characters that are safe inside a quoted header value.
function safeFileName(path) {
  const base = String(path).split("/").pop() || "video";
  return base.replace(/[^\w.\- ]+/g, "_").slice(0, 150) || "video";
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

  if (!r2Configured()) {
    res.status(503).json({ error: "Storage isn't configured yet." });
    return;
  }

  try {
    const user = await verifyUser(accessToken);
    if (!user) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }

    if ((await callerRole(user.id, accessToken)) !== "admin") {
      res.status(403).json({ error: "Only an admin account can download videos here." });
      return;
    }

    const rows = await userSelect("game_videos", `id=eq.${encodeURIComponent(gameVideoId)}&select=*`, accessToken);
    const gameVideo = rows[0];
    if (!gameVideo || !(await storagePathIsTrusted(gameVideo))) {
      res.status(404).json({ error: "Video not found." });
      return;
    }

    const url = await getSignedUrl(
      r2Client(),
      new GetObjectCommand({
        Bucket: process.env.R2_BUCKET_NAME,
        Key: gameVideo.storage_path,
        ResponseContentDisposition: `attachment; filename="${safeFileName(gameVideo.storage_path)}"`,
      }),
      { expiresIn: 60 * 10 } // 10 minutes -- just long enough to start the download
    );

    res.status(200).json({ url });
  } catch (error) {
    sendServerError(res, error, "Could not create a download link.");
  }
}
