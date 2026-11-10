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
  storagePathIsTrusted, sendServerError, SUPABASE_URL, userHeaders,
} from "../_lib/supabase.js";

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const { accessToken, gameVideoId, keepOtherFiles } = req.body || {};
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

    // Remove only Part 1 of a request: the database promotes the next file
    // to be the request (promote_next_video_part, admin only), then the
    // old file leaves storage.
    if (keepOtherFiles) {
      if (gameVideo.parent_video_id) {
        res.status(400).json({ error: "That isn't the first file of a request." });
        return;
      }
      const rpc = await fetch(`${SUPABASE_URL}/rest/v1/rpc/promote_next_video_part`, {
        method: "POST",
        headers: userHeaders(accessToken, { "Content-Type": "application/json" }),
        body: JSON.stringify({ p_root: gameVideo.id }),
      });
      if (!rpc.ok) {
        let detail = "";
        try { detail = (await rpc.json()).message || ""; } catch (e) { /* ignore */ }
        res.status(rpc.status === 401 || rpc.status === 403 ? 403 : 400).json({ error: detail || "Could not remove the first file." });
        return;
      }
      const out = await rpc.json();
      if (fileIsOwn && r2Configured()) {
        try {
          await r2Client().send(new DeleteObjectCommand({
            Bucket: process.env.R2_BUCKET_NAME,
            Key: gameVideo.storage_path,
          }));
        } catch (r2Error) {
          console.error("R2 delete failed after the first file was removed:", r2Error);
        }
      }
      res.status(200).json({ deleted: true, newRootId: out.newRootId, partIds: [] });
      return;
    }

    // A request's extra files (supabase/migrations/20261024_video_parts.sql)
    // go with it: their rows are removed by the database, so note which
    // files to remove now. Without that migration there is no such
    // column and nothing to do.
    const partFiles = [];
    const partIds = [];
    if (!gameVideo.parent_video_id) {
      try {
        const parts = await userSelect("game_videos", `parent_video_id=eq.${encodeURIComponent(gameVideoId)}&select=*`, accessToken);
        for (const part of parts) {
          partIds.push(part.id);
          if (await storagePathIsTrusted(part)) partFiles.push(part.storage_path);
        }
      } catch (partsError) {
        // Column not created yet.
      }
    }

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

    if (r2Configured()) {
      for (const key of partFiles) {
        try {
          await r2Client().send(new DeleteObjectCommand({
            Bucket: process.env.R2_BUCKET_NAME,
            Key: key,
          }));
        } catch (r2Error) {
          console.error("R2 delete of an extra file failed after the row was removed:", r2Error);
        }
      }
    }

    res.status(200).json({ deleted: true, partIds });
  } catch (error) {
    sendServerError(res, error, "Could not delete the video.");
  }
}
