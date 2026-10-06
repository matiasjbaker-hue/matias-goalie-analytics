// ============================================================
// R2 UPLOAD — STEP 1: START MULTIPART UPLOAD
// ============================================================
// Raw game film lives in Cloudflare R2 (S3-compatible; real free tier,
// zero egress). This does NOT receive the file itself -- it creates an
// R2 multipart upload and hands back presigned PUT URLs for each part,
// so the browser uploads parts directly to R2 and Vercel's request
// size/time limits never apply to the video bytes.
//
// Setup required in Vercel:
//   - R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY,
//     R2_BUCKET_NAME -- Cloudflare dashboard: R2 -> Manage API Tokens
//     (scope it to Object Read & Write on this bucket only).
//   - In the bucket settings, add a lifecycle rule that aborts
//     incomplete multipart uploads after a few days, so interrupted
//     uploads don't sit billed as storage forever.

import { CreateMultipartUploadCommand, UploadPartCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import {
  verifyUser, callerHasAccess, callerRole, r2Configured, r2Client, sendServerError, UUID_RE,
} from "../_lib/supabase.js";

// 25MB per part -- keeps the request count reasonable for a multi-GB
// game file, while a failed part is a cheap retry.
const PART_SIZE_BYTES = 25 * 1024 * 1024;

// A full game at high bitrate fits well inside this. Anything larger is
// either a mistake or abuse, and an unbounded size would make this
// function mint millions of presigned URLs.
const MAX_FILE_BYTES = 20 * 1024 * 1024 * 1024; // 20 GB

// Presigned URLs are valid this long from creation. Generous on purpose:
// on a slow connection, later parts may start hours after this request.
const PRESIGN_EXPIRY_SECONDS = 60 * 60 * 24;

// Only video files are stored; anything else could be served back from
// the bucket as something other than video.
function safeContentType(value) {
  const type = String(value || "").toLowerCase().trim();
  return /^video\/[a-z0-9.+-]{1,40}$/.test(type) ? type : "video/mp4";
}

// The original file name ends up in the object key and later in
// download headers; keep it to plain, header-safe characters.
function safeFileName(value) {
  const cleaned = String(value || "")
    .split(/[\\/]/).pop()
    .replace(/[^\w.\- ]+/g, "_")
    .replace(/\.{2,}/g, ".")
    .trim()
    .slice(0, 120);
  return cleaned || "video.mp4";
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  // ownerId: an admin uploading a clip for a goalie stores it in that
  // goalie's folder, so the file and its game_videos row match owners.
  const { accessToken, fileName, fileSizeBytes, contentType, ownerId } = req.body || {};
  const size = Number(fileSizeBytes);

  if (!accessToken || !fileName || !fileSizeBytes) {
    res.status(400).json({ error: "Missing accessToken, fileName, or fileSizeBytes." });
    return;
  }

  if (!Number.isFinite(size) || size <= 0 || size > MAX_FILE_BYTES) {
    res.status(400).json({ error: "That file is too large. The limit is 20 GB per video." });
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
    if (!(await callerHasAccess(accessToken))) {
      res.status(402).json({ error: "Your GoalieIQ access isn't active." });
      return;
    }

    let folder = user.id;
    if (ownerId && ownerId !== user.id) {
      if (typeof ownerId !== "string" || !UUID_RE.test(ownerId) || (await callerRole(user.id, accessToken)) !== "admin") {
        res.status(403).json({ error: "Only an admin can upload on behalf of another account." });
        return;
      }
      folder = ownerId;
    }

    const key = `${folder}/${Date.now()}_${safeFileName(fileName)}`;
    const client = r2Client();

    const created = await client.send(new CreateMultipartUploadCommand({
      Bucket: process.env.R2_BUCKET_NAME,
      Key: key,
      ContentType: safeContentType(contentType),
    }));

    const uploadId = created.UploadId;
    const partCount = Math.ceil(size / PART_SIZE_BYTES);

    const partUrls = await Promise.all(
      Array.from({ length: partCount }, (_, i) => i + 1).map(async partNumber => ({
        partNumber,
        url: await getSignedUrl(
          client,
          new UploadPartCommand({
            Bucket: process.env.R2_BUCKET_NAME,
            Key: key,
            UploadId: uploadId,
            PartNumber: partNumber,
          }),
          { expiresIn: PRESIGN_EXPIRY_SECONDS }
        ),
      }))
    );

    res.status(200).json({ key, uploadId, partSize: PART_SIZE_BYTES, partUrls });
  } catch (error) {
    sendServerError(res, error, "Could not start the upload.");
  }
}
