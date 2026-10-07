// ============================================================
// POST /api/admin/create-request -- admin adds a video for a goalie
// (served through api/admin/[action].js)
// ============================================================
// Body: { accessToken, goalieId, storagePath, jerseyColor,
//         gameId?, requestedGame?: { date, opponent, home_away, season } }
//
// The browser has already uploaded the file into the goalie's own
// folder (r2-start-upload with ownerId). This creates the request row
// for that goalie, exactly as if they had sent it, so it appears in the
// review queue and on their uploads list. Written with the service key
// after checking the caller is an admin, the goalie exists, the file is
// in their folder, and any chosen game is theirs.

import { verifyUser, getProfile, serviceSelect, SUPABASE_URL } from "./billing.js";
import { UUID_RE } from "./supabase.js";

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

function text(value, max) {
  const s = String(value ?? "").replace(/\s+/g, " ").trim();
  return s ? s.slice(0, max) : null;
}

async function serviceInsert(table, row) {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${encodeURIComponent(table)}`, {
    method: "POST",
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
      Prefer: "return=representation",
    },
    body: JSON.stringify(row),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`Supabase ${res.status} inserting into ${table}: ${body}`);
  return JSON.parse(body)[0];
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }
  if (!process.env.SUPABASE_SERVICE_ROLE_KEY) {
    res.status(503).json({ error: "Server isn't configured for this yet (missing SUPABASE_SERVICE_ROLE_KEY)." });
    return;
  }

  const { accessToken, goalieId, storagePath, jerseyColor, gameId, requestedGame } = req.body || {};

  if (!UUID_RE.test(String(goalieId || ""))) {
    res.status(400).json({ error: "Pick a goalie." });
    return;
  }
  const path = String(storagePath || "");
  if (!path.startsWith(`${goalieId}/`) || path.includes("..") || path.length > 500) {
    res.status(400).json({ error: "The video wasn't uploaded into that goalie's folder." });
    return;
  }
  const jersey = text(jerseyColor, 40);
  if (!jersey) {
    res.status(400).json({ error: "Enter the goalie's team jersey colour." });
    return;
  }

  try {
    const caller = await verifyUser(accessToken);
    if (!caller) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }
    const callerProfile = await getProfile(caller.id);
    if (!callerProfile || callerProfile.role !== "admin") {
      res.status(403).json({ error: "Only an admin can add videos for a goalie." });
      return;
    }

    const goalie = await getProfile(goalieId);
    if (!goalie) {
      res.status(404).json({ error: "That goalie's account wasn't found." });
      return;
    }

    let game = null;
    let requested = null;

    if (gameId !== null && gameId !== undefined && gameId !== "") {
      const gid = Number(gameId);
      if (!Number.isInteger(gid) || gid <= 0) {
        res.status(400).json({ error: "That game isn't valid." });
        return;
      }
      const rows = await serviceSelect("Games", `select=id,user_id&id=eq.${gid}`);
      if (!rows[0] || rows[0].user_id !== goalieId) {
        res.status(400).json({ error: "That game doesn't belong to this goalie." });
        return;
      }
      game = gid;
    } else {
      const rg = requestedGame || {};
      const opponent = text(rg.opponent, 80);
      if (!opponent) {
        res.status(400).json({ error: "Enter the opponent, or pick one of the goalie's games." });
        return;
      }
      requested = {
        date: DATE_RE.test(String(rg.date || "")) ? rg.date : null,
        opponent,
        home_away: rg.home_away === "Home" || rg.home_away === "Away" ? rg.home_away : null,
        season: text(rg.season, 40),
      };
    }

    const existing = await serviceSelect("game_videos", `select=id&storage_path=eq.${encodeURIComponent(path)}`);
    if (existing.length) {
      res.status(409).json({ error: "This file is already attached to a request." });
      return;
    }

    const row = await serviceInsert("game_videos", {
      user_id: goalieId,
      game_id: game,
      requested_game: requested,
      storage_path: path,
      team_jersey_color: jersey,
      status: "uploaded",
      review_status: "received",
    });

    res.status(200).json({ gameVideoId: row.id });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: "Couldn't create the request.", detail: String(error && error.message || error).slice(0, 300) });
  }
}
