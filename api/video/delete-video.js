// ============================================================
// VIDEO PIPELINE — DELETE AN UPLOADED VIDEO
// ============================================================
// Deletes both the actual video file in R2 and its game_videos row.
// Deleting the row cascades to any shot_drafts tied to it (ON DELETE
// CASCADE), so there's nothing extra to clean up on that side.
//
// RLS on game_videos ("delete own or admin game_videos") decides who
// may delete; this endpoint works with the caller's own token.

import { DeleteObjectCommand } from "@aws-sdk/client-s3";
import {
  verifyUser, userSelect, userDelete, r2Configured, r2Client,
  storagePathIsTrusted, sendServerError,
} from "../_lib/supabase.js";

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
    const user = await verifyUser(accessToken);
    if (!user) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }

    const filter = `id=eq.${encodeURIComponent(gameVideoId)}`;
    const rows = await userSelect("game_videos", `${filter}&select=*`, accessToken);
    const gameVideo = rows[0];
    if (!gameVideo) {
      // Already gone, or RLS hid it -- either way, nothing left to do.
      res.status(404).json({ error: "Video not found (or you don't have permission to delete it)." });
      return;
    }

    // Decide about the file before the row goes: the trust check looks
    // for other rows that reference the same path.
    const fileIsOwn = await storagePathIsTrusted(gameVideo);

    // Delete the row first: RLS decides here whether the caller may
    // delete at all, so a file is never removed for someone who
    // couldn't remove its record.
    const deletedRows = await userDelete("game_videos", filter, accessToken);
    if (!deletedRows || !deletedRows.length) {
      res.status(403).json({ error: "Nothing was deleted -- you may not have permission to delete this video." });
      return;
    }

    // If storage isn't configured, the record is still removed; better an
    // orphaned file than being stuck unable to delete anything.
    if (!fileIsOwn) {
      console.warn("Skipped R2 delete for a path this row doesn't own:", gameVideo.id);
    } else if (r2Configured()) {
      try {
        await r2Client().send(new DeleteObjectCommand({
          Bucket: process.env.R2_BUCKET_NAME,
          Key: gameVideo.storage_path,
        }));
      } catch (r2Error) {
        console.error("R2 delete failed after the row was removed:", r2Error);
      }
    }

    res.status(200).json({ deleted: true });
  } catch (error) {
    sendServerError(res, error, "Could not delete the video.");
  }
}
