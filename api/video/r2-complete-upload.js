// ============================================================
// R2 UPLOAD — STEP 2: COMPLETE MULTIPART UPLOAD
// ============================================================
// Call once every part from r2-start-upload.js has been PUT
// successfully. Stitches the parts into one object in R2.

import {
  S3Client,
  CompleteMultipartUploadCommand,
  AbortMultipartUploadCommand,
} from "@aws-sdk/client-s3";

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

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const { accessToken, key, uploadId, parts, abort } = req.body || {};

  if (!accessToken || !key || !uploadId) {
    res.status(400).json({ error: "Missing accessToken, key, or uploadId." });
    return;
  }

  try {
    const user = await verifyAccessToken(accessToken);
    if (!user) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }

    // Only the user whose folder this key lives under should be able
    // to complete (or abort) an upload into it.
    if (!key.startsWith(`${user.id}/`)) {
      res.status(403).json({ error: "This upload does not belong to you." });
      return;
    }

    const client = r2Client();

    if (abort) {
      await client.send(
        new AbortMultipartUploadCommand({
          Bucket: process.env.R2_BUCKET_NAME,
          Key: key,
          UploadId: uploadId,
        })
      );
      res.status(200).json({ aborted: true });
      return;
    }

    if (!parts || !parts.length) {
      res.status(400).json({ error: "Missing parts list." });
      return;
    }

    await client.send(
      new CompleteMultipartUploadCommand({
        Bucket: process.env.R2_BUCKET_NAME,
        Key: key,
        UploadId: uploadId,
        MultipartUpload: {
          Parts: parts
            .slice()
            .sort((a, b) => a.PartNumber - b.PartNumber),
        },
      })
    );

    res.status(200).json({ key });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: error.message || "Something went wrong." });
  }
}
