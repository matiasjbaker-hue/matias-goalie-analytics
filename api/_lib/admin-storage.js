// ============================================================
// POST /api/admin/storage -- what's in the R2 bucket (admin only)
// (served through api/admin/[action].js)
// ============================================================
// Body: { accessToken, op: "scan" }
//   -> every object with its size, tied back to its game_videos row
//      (full upload / clip / no row at all) and how many shots lean on it.
// Body: { accessToken, op: "delete-orphans", keys: [...] }
//   -> deletes bucket files that no game_videos row points at. Only keys
//      that are in the live listing AND unreferenced are removed.
// Body: { accessToken, op: "delete-video", videoId }
//   -> detaches any shots pointing at the video (the shots stay, they just
//      lose their Watch clip), then deletes the record and the file.

import { ListObjectsV2Command, DeleteObjectCommand } from "@aws-sdk/client-s3";
import {
  verifyUser, userSelect, userUpdate, userDelete, callerRole, r2Configured, r2Client, sendServerError, UUID_RE,
} from "./supabase.js";

async function listAll() {
  const out = [];
  let token;
  do {
    const page = await r2Client().send(new ListObjectsV2Command({
      Bucket: process.env.R2_BUCKET_NAME, ContinuationToken: token,
    }));
    for (const o of page.Contents || []) {
      out.push({ key: o.Key, size: Number(o.Size) || 0, modified: o.LastModified ? o.LastModified.toISOString() : null });
    }
    token = page.IsTruncated ? page.NextContinuationToken : undefined;
  } while (token);
  return out;
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const { accessToken, op, keys } = req.body || {};

  try {
    const user = await verifyUser(accessToken);
    if (!user) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }
    if ((await callerRole(user.id, accessToken)) !== "admin") {
      res.status(403).json({ error: "Admins only." });
      return;
    }
    if (!r2Configured()) {
      res.status(503).json({ error: "File storage isn't configured on the server." });
      return;
    }

    if (op === "delete-video") {
      const { videoId } = req.body || {};
      if (typeof videoId !== "string" || !UUID_RE.test(videoId)) {
        res.status(400).json({ error: "Missing video." });
        return;
      }
      const filter = `id=eq.${encodeURIComponent(videoId)}`;
      const rows = await userSelect("game_videos", `${filter}&select=id,storage_path`, accessToken);
      if (!rows[0]) {
        res.status(404).json({ error: "Video not found." });
        return;
      }
      // Shots.game_video_id has no cascade, so detach first or the delete fails.
      await userUpdate(
        "Shots",
        `game_video_id=eq.${encodeURIComponent(videoId)}`,
        { game_video_id: null, clip_start_seconds: null, clip_end_seconds: null },
        accessToken
      );
      const path = rows[0].storage_path;
      const others = await userSelect("game_videos", `storage_path=eq.${encodeURIComponent(path)}&id=neq.${encodeURIComponent(videoId)}&select=id`, accessToken);
      const gone = await userDelete("game_videos", filter, accessToken);
      if (!gone || !gone.length) {
        res.status(403).json({ error: "Nothing was deleted." });
        return;
      }
      if (!others.length && path) {
        await r2Client().send(new DeleteObjectCommand({ Bucket: process.env.R2_BUCKET_NAME, Key: path }));
      }
      res.status(200).json({ deleted: true });
      return;
    }

    const objects = await listAll();
    const videos = await userSelect(
      "game_videos",
      "select=id,storage_path,status,review_status,game_id,user_id,created_at&limit=5000",
      accessToken
    );
    const byPath = new Map();
    for (const v of videos) {
      if (!byPath.has(v.storage_path)) byPath.set(v.storage_path, []);
      byPath.get(v.storage_path).push(v);
    }

    if (op === "delete-orphans") {
      const wanted = Array.isArray(keys) ? keys.filter(k => typeof k === "string").slice(0, 200) : [];
      const live = new Set(objects.map(o => o.key));
      let deleted = 0;
      let freed = 0;
      for (const key of wanted) {
        if (!live.has(key) || byPath.has(key)) continue;
        await r2Client().send(new DeleteObjectCommand({ Bucket: process.env.R2_BUCKET_NAME, Key: key }));
        deleted += 1;
        freed += objects.find(o => o.key === key).size;
      }
      res.status(200).json({ deleted, freed });
      return;
    }

    const profs = await userSelect("profiles", "select=id,full_name&limit=5000", accessToken);
    const nameOf = new Map(profs.map(p => [p.id, p.full_name || null]));

    const shots = await userSelect("Shots", "select=game_video_id&game_video_id=not.is.null&limit=20000", accessToken);
    const shotCount = new Map();
    for (const s of shots) shotCount.set(s.game_video_id, (shotCount.get(s.game_video_id) || 0) + 1);

    const items = objects.map(o => {
      const rows = byPath.get(o.key) || [];
      const row = rows[0] || null;
      const folder = o.key.split("/")[0];
      const kind = !row ? "orphan" : row.status === "clip" ? "clip" : "full";
      return {
        key: o.key, size: o.size, modified: o.modified, kind,
        owner: nameOf.get(row ? row.user_id : folder) || (row ? "Unknown" : (UUID_RE.test(folder) ? "Unknown" : "—")),
        owner_id: row ? row.user_id : (UUID_RE.test(folder) ? folder : null),
        video_id: row ? row.id : null,
        status: row ? row.status : null,
        review_status: row ? row.review_status : null,
        game_id: row ? row.game_id : null,
        shots: rows.reduce((n, r) => n + (shotCount.get(r.id) || 0), 0),
      };
    }).sort((a, b) => b.size - a.size);

    const sum = kind => items.filter(i => i.kind === kind).reduce((n, i) => n + i.size, 0);
    res.status(200).json({
      total: items.reduce((n, i) => n + i.size, 0),
      count: items.length,
      by_kind: {
        full: { bytes: sum("full"), count: items.filter(i => i.kind === "full").length },
        clip: { bytes: sum("clip"), count: items.filter(i => i.kind === "clip").length },
        orphan: { bytes: sum("orphan"), count: items.filter(i => i.kind === "orphan").length },
      },
      items,
    });
  } catch (error) {
    sendServerError(res, error, "Couldn't read file storage.");
  }
}
