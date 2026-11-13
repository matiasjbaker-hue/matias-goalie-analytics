// ============================================================
// VIDEO PIPELINE — SIGNED URL TO WATCH (OR DOWNLOAD) A VIDEO
// ============================================================
// POST { accessToken, gameVideoId, download? }
//
// Watch (default): an inline-playable URL. Authorization is delegated to
// Supabase RLS on game_videos ("read own or assigned or admin
// game_videos") by fetching the row with the caller's OWN access token.
// If RLS returns zero rows, this 404s.
//
// Download (download: true): the URL carries a Content-Disposition that
// forces a file download. Admins can download any video; coaches can
// download the shot clips (status "clip") of their goalies, nothing else.
// This used to be its own endpoint (get-download-url.js); it lives here so
// the project stays within Vercel Hobby's 12-function limit.
//
// Batch: { accessToken, gameVideoIds: [...], download: true, fileNames?: [...] }
// returns { items: [{ id, url, fileName }] } for up to 100 clips at once
// (the page uses it for "Download all clips"). Anything the caller can't
// download is left out, and "skipped" says how many.
//
// R2 serves range requests on GetObject, so the browser's <video>
// element can seek within the file using this one signed URL.

import { GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import {
  verifyUser, callerRole, userSelect, r2Configured, r2Client,
  storagePathIsTrusted, sendServerError,
} from "../_lib/supabase.js";

// Long enough to watch a shot, rewind, watch it again, without the URL
// expiring mid-viewing -- short enough that a leaked link isn't useful
// for long.
const WATCH_URL_EXPIRY_SECONDS = 60 * 30;
// Just long enough to start the download.
const DOWNLOAD_URL_EXPIRY_SECONDS = 60 * 10;

// Keep only characters that are safe inside a quoted header value.
function safeFileName(path) {
  const base = String(path).split("/").pop() || "video";
  return base.replace(/[^\w.\- ]+/g, "_").slice(0, 150) || "video";
}

// A friendly name for a clip, always ending in .mp4.
function clipFileName(wanted, path) {
  const cleaned = String(wanted || "").replace(/[^\w.\- ()]+/g, "_").replace(/\.mp4$/i, "").trim().slice(0, 140);
  return cleaned ? `${cleaned}.mp4` : safeFileName(path);
}

const MAX_BATCH = 100;

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const { accessToken, gameVideoId, download, gameVideoIds, fileNames } = req.body || {};
  const batch = Array.isArray(gameVideoIds) ? gameVideoIds.slice(0, MAX_BATCH) : null;
  if (!accessToken || (!gameVideoId && !(batch && batch.length))) {
    res.status(400).json({ error: "Missing accessToken or gameVideoId." });
    return;
  }
  if (batch && !download) {
    res.status(400).json({ error: "Batch is for downloads only." });
    return;
  }

  if (!r2Configured()) {
    res.status(503).json({ error: "Video storage isn't configured yet." });
    return;
  }

  try {
    const user = await verifyUser(accessToken);
    if (!user) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }

    const role = download ? await callerRole(user.id, accessToken) : null;
    if (download && role !== "admin" && role !== "coach") {
      res.status(403).json({ error: "Only an admin or coach account can download videos here." });
      return;
    }

    if (batch) {
      const items = [];
      let skipped = 0;
      for (let i = 0; i < batch.length; i++) {
        const id = String(batch[i] || "");
        if (!/^\d+$/.test(id)) { skipped++; continue; }
        const found = await userSelect("game_videos", `id=eq.${encodeURIComponent(id)}&select=*`, accessToken);
        const row = found[0];
        // A coach may only take shot clips; the row is only visible if RLS lets them see it.
        if (!row || (role !== "admin" && row.status !== "clip") || !(await storagePathIsTrusted(row))) { skipped++; continue; }
        const fileName = clipFileName(Array.isArray(fileNames) ? fileNames[i] : "", row.storage_path);
        const url = await getSignedUrl(r2Client(), new GetObjectCommand({
          Bucket: process.env.R2_BUCKET_NAME,
          Key: row.storage_path,
          ResponseContentDisposition: `attachment; filename="${fileName}"`,
        }), { expiresIn: DOWNLOAD_URL_EXPIRY_SECONDS });
        items.push({ id, url, fileName });
      }
      res.status(200).json({ items, skipped });
      return;
    }

    const rows = await userSelect("game_videos", `id=eq.${encodeURIComponent(gameVideoId)}&select=*`, accessToken);
    const gameVideo = rows[0];

    if (download && role !== "admin" && gameVideo && gameVideo.status !== "clip") {
      res.status(403).json({ error: "Coaches can download shot clips, not the full game film." });
      return;
    }

    // RLS decides whether the row is visible; the path check stops a row
    // that points into someone else's folder from unlocking their file.
    if (!gameVideo || !(await storagePathIsTrusted(gameVideo))) {
      res.status(404).json({ error: "Video not found, or you don't have access to it." });
      return;
    }

    const command = new GetObjectCommand({
      Bucket: process.env.R2_BUCKET_NAME,
      Key: gameVideo.storage_path,
      ...(download
        ? { ResponseContentDisposition: `attachment; filename="${safeFileName(gameVideo.storage_path)}"` }
        : {}),
    });

    const url = await getSignedUrl(r2Client(), command, {
      expiresIn: download ? DOWNLOAD_URL_EXPIRY_SECONDS : WATCH_URL_EXPIRY_SECONDS,
    });

    res.status(200).json({ url });
  } catch (error) {
    sendServerError(res, error, download ? "Could not create a download link." : "Could not load the video.");
  }
}
