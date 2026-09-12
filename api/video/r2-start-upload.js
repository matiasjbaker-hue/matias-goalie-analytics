// ============================================================
// R2 UPLOAD — STEP 1: START MULTIPART UPLOAD
// ============================================================
// Replaces Supabase Storage as the home for raw game film. Why:
// Supabase's Free plan hard-caps file size at 50MB (and only gives
// 1GB total storage) with no workaround short of upgrading to Pro.
// Cloudflare R2 has a real free tier for this (10GB storage, zero
// egress fees -- important since every video also gets fetched back
// out by memories.ai for indexing), and is S3-compatible, so this
// uses the standard AWS SDK pointed at R2's S3-compatible endpoint.
//
// This does NOT receive the file itself -- it creates an R2
// multipart upload and hands back presigned PUT URLs for each part,
// so the browser uploads parts directly to R2. This function's own
// body never touches the video bytes, so it's unaffected by
// Vercel's serverless request-size/time limits regardless of how
// large the video is.
//
// Setup required in Vercel:
//   - R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY,
//     R2_BUCKET_NAME -- from Cloudflare dashboard: R2 -> Manage
//     API Tokens (create one scoped to Object Read & Write on this
//     bucket only, not your whole account).
//   - In the R2 bucket's settings, set a lifecycle rule to abort
//     incomplete multipart uploads after a few days -- otherwise an
//     interrupted upload that's never resumed or retried leaves
//     orphaned part data billed as storage indefinitely.

import {
  S3Client,
  CreateMultipartUploadCommand,
  UploadPartCommand,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

const SUPABASE_URL = "https://iiuqxxrrruvwvfehrzic.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ";

// 25MB per part -- big enough to keep the number of requests
// reasonable for a multi-GB game file, small enough that a single
// failed part is a cheap retry, not a lost hour of upload.
const PART_SIZE_BYTES = 25 * 1024 * 1024;

// Presigned URLs are valid this long from creation. Generous on
// purpose: for a slow home connection, later parts might not start
// uploading until hours after the request that minted their URL.
const PRESIGN_EXPIRY_SECONDS = 60 * 60 * 24;

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

  const { accessToken, fileName, fileSizeBytes, contentType } =
    req.body || {};

  if (!accessToken || !fileName || !fileSizeBytes) {
    res.status(400).json({
      error: "Missing accessToken, fileName, or fileSizeBytes.",
    });
    return;
  }

  if (
    !process.env.R2_ACCOUNT_ID ||
    !process.env.R2_ACCESS_KEY_ID ||
    !process.env.R2_SECRET_ACCESS_KEY ||
    !process.env.R2_BUCKET_NAME
  ) {
    res.status(503).json({
      error:
        "Video storage isn't configured yet -- add R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, and R2_BUCKET_NAME in Vercel project settings.",
    });
    return;
  }

  try {
    const user = await verifyAccessToken(accessToken);
    if (!user) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }

    const key = `${user.id}/${Date.now()}_${fileName}`;
    const client = r2Client();

    const created = await client.send(
      new CreateMultipartUploadCommand({
        Bucket: process.env.R2_BUCKET_NAME,
        Key: key,
        ContentType: contentType || "video/mp4",
      })
    );

    const uploadId = created.UploadId;
    const partCount = Math.ceil(fileSizeBytes / PART_SIZE_BYTES);

    const partUrls = [];
    for (let partNumber = 1; partNumber <= partCount; partNumber++) {
      const url = await getSignedUrl(
        client,
        new UploadPartCommand({
          Bucket: process.env.R2_BUCKET_NAME,
          Key: key,
          UploadId: uploadId,
          PartNumber: partNumber,
        }),
        { expiresIn: PRESIGN_EXPIRY_SECONDS }
      );
      partUrls.push({ partNumber, url });
    }

    res.status(200).json({
      key,
      uploadId,
      partSize: PART_SIZE_BYTES,
      partUrls,
    });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: error.message || "Something went wrong." });
  }
}
