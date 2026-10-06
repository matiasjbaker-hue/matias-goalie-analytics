// ============================================================
// R2 UPLOAD — STEP 2: COMPLETE MULTIPART UPLOAD
// ============================================================
// Call once every part from r2-start-upload.js has been PUT
// successfully. Stitches the parts into one object in R2.

import { CompleteMultipartUploadCommand, AbortMultipartUploadCommand } from "@aws-sdk/client-s3";
import { verifyUser, callerRole, r2Configured, r2Client, sendServerError, UUID_RE } from "../_lib/supabase.js";

// Matches the 20 GB / 25 MB limits in r2-start-upload.js, with headroom.
const MAX_PARTS = 1000;

function cleanParts(parts) {
  if (!Array.isArray(parts) || !parts.length || parts.length > MAX_PARTS) return null;
  const out = [];
  for (const p of parts) {
    const n = Number(p && p.PartNumber);
    const etag = p && typeof p.ETag === "string" ? p.ETag : null;
    if (!Number.isInteger(n) || n < 1 || n > MAX_PARTS || !etag || etag.length > 200) return null;
    out.push({ PartNumber: n, ETag: etag });
  }
  return out.sort((a, b) => a.PartNumber - b.PartNumber);
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const { accessToken, key, uploadId, parts, abort } = req.body || {};

  if (!accessToken || typeof key !== "string" || typeof uploadId !== "string") {
    res.status(400).json({ error: "Missing accessToken, key, or uploadId." });
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

    // Only the user whose folder this key lives under can complete (or
    // abort) an upload into it; an admin may finish uploads they started
    // into a goalie's folder (see ownerId in r2-start-upload.js).
    const folder = key.split("/")[0];
    const ownsFolder = folder === user.id;
    const adminForOwner = !ownsFolder && UUID_RE.test(folder) && (await callerRole(user.id, accessToken)) === "admin";
    if (key.includes("..") || !(ownsFolder || adminForOwner)) {
      res.status(403).json({ error: "This upload does not belong to you." });
      return;
    }

    const client = r2Client();

    if (abort) {
      await client.send(new AbortMultipartUploadCommand({
        Bucket: process.env.R2_BUCKET_NAME,
        Key: key,
        UploadId: uploadId,
      }));
      res.status(200).json({ aborted: true });
      return;
    }

    const cleaned = cleanParts(parts);
    if (!cleaned) {
      res.status(400).json({ error: "Missing or invalid parts list." });
      return;
    }

    await client.send(new CompleteMultipartUploadCommand({
      Bucket: process.env.R2_BUCKET_NAME,
      Key: key,
      UploadId: uploadId,
      MultipartUpload: { Parts: cleaned },
    }));

    res.status(200).json({ key });
  } catch (error) {
    sendServerError(res, error, "Could not finish the upload.");
  }
}
