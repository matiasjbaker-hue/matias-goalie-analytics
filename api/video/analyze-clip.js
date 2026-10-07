// ============================================================
// AI CLIP TAGGING — read one shot clip, return the shot
// ============================================================
// POST { accessToken, frames: [{ t, data }], context, mode? }
//   or { accessToken, gameVideoId, times: [seconds], width?, context, mode? }
//
// With gameVideoId + times, the frames are pulled from the stored video
// on the server (ffmpeg over a signed R2 URL), so the browser never has
// to read video pixels and the bucket needs no CORS rules for it.
//
// mode "tag" (default): the frames are one shot; returns its fields.
// mode "detect": the frames are evenly spaced stills from a full game
// (a few seconds apart); returns the timestamps where a shot on the
// tracked goalie's net appears to happen. The admin review screen
// scans a game with "detect", then runs "tag" on a short burst of
// frames around each hit.
//
// The browser pulls a handful of still frames out of one pre-trimmed
// shot clip (it already has the file in hand while uploading it), so
// no video ever passes through this function: only small JPEGs. Claude
// reads the frames and returns the same fields the Live Tag toolbar
// records. The browser then saves the shot through the normal Live Tag
// path, marked ai_tagged, where a human can correct any field later.
//
// Admin-only for now: it spends API budget on every clip.
//
// Vercel environment variables:
//   ANTHROPIC_API_KEY   the same key AI Coach uses
//   CLIP_AI_MODEL       optional; defaults to claude-opus-5-5

import { GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import {
  verifyUser, callerRole, userSelect, r2Configured, r2Client,
  storagePathIsTrusted, sendServerError,
} from "../_lib/supabase.js";
import { claude, claudeConfigured, textOf } from "../_lib/claude.js";
import { ffmpegAvailable, grabFrames } from "../_lib/frames.js";

const MODEL = (process.env.CLIP_AI_MODEL || "claude-opus-5-5").trim();

const MAX_FRAMES = 16;
// ~450 KB of JPEG per frame; the browser sends ~640px frames at ~60 KB.
const MAX_FRAME_BASE64 = 600 * 1024;

const SHOT_TYPES = ["Wrist", "Slap", "Snap", "Backhand", "Tip", "One-Timer", "unknown"];
const RELEASE_TYPES = ["unclear", "one_timer", "catch_and_release", "quick_release", "extended_possession"];
const REBOUND_TAGS = [
  "skip",
  "glove_caught", "glove_rebound", "glove_goal",
  "blocker_good", "blocker_bad", "blocker_goal",
  "midsection_good", "midsection_bad", "midsection_goal",
  "pad_stick_good", "pad_stick_bad", "pad_stick_goal",
];

const SHOT_SCHEMA = {
  type: "object",
  properties: {
    shot_detected: { type: "boolean", description: "False when no shot on goal is visible in these frames." },
    outcome: { type: "string", enum: ["save", "goal"] },
    loc_x: { type: "number", description: "Release point, feet left(-)/right(+) of the goal's center line, from the goalie's view. -42.5 to 42.5." },
    loc_y: { type: "number", description: "Release point, feet out from the goal line toward the blue line. -11 (behind the net) to 64 (blue line)." },
    shot_type: { type: "string", enum: SHOT_TYPES },
    release_type: { type: "string", enum: RELEASE_TYPES },
    rush: { type: "boolean" },
    rebound: { type: "boolean", description: "This shot is itself a rebound of an earlier shot." },
    screened: { type: "boolean" },
    breakaway: { type: "boolean" },
    cross_ice: { type: "boolean", description: "A pass crossed the middle of the ice right before the shot." },
    deflection: { type: "boolean" },
    rebound_control: { type: "string", enum: REBOUND_TAGS, description: "Where the goalie made contact and what happened to the puck. skip when unclear." },
    confidence: { type: "number", description: "0 to 1: how sure you are of outcome and location together." },
    notes: { type: "string", description: "One short sentence on anything a human reviewer should check." },
  },
  required: [
    "shot_detected", "outcome", "loc_x", "loc_y", "shot_type", "release_type",
    "rush", "rebound", "screened", "breakaway", "cross_ice", "deflection",
    "rebound_control", "confidence", "notes",
  ],
  additionalProperties: false,
};

const SYSTEM_PROMPT = `You tag hockey goaltending clips for a stats platform. Each request is ONE pre-trimmed clip of one shot against the goalie being tracked, given as still frames in time order with their timestamps.

Record what the frames show, the way a goalie coach logging the game would:
- outcome: "goal" only if the puck clearly ends up in the net; otherwise "save".
- loc_x / loc_y: where the shooter RELEASED the puck, in feet, measured from the center of the tracked goalie's goal line. y runs out toward the blue line (0 = goal line, 20 = faceoff dots, 64 = blue line, negative = behind the net). x runs across the ice from the goalie's own point of view looking out: negative = the goalie's left, positive = the goalie's right; the faceoff dots are at x = -22 and 22, the boards at -42.5 and 42.5. Use rink markings (crease, dots, circles, hashmarks, blue line) to estimate.
- shot_type, release_type, and the situation flags: mark only what you can see. A flag you cannot judge is false. Use "unknown" / "unclear" rather than guessing a type.
- rebound_control: the part of the goalie that touched the puck and the result (caught, rebound to a dangerous area = bad, controlled away = good, or a goal). "skip" when contact isn't visible.
- shot_detected false if the frames show no shot on goal at all; the other fields are then ignored.

Be conservative. A human reviews these later; a clear "unknown" is more useful than a confident guess. Keep confidence honest.`;

const DETECT_SCHEMA = {
  type: "object",
  properties: {
    events: {
      type: "array",
      items: {
        type: "object",
        properties: {
          frame: { type: "integer", description: "1-based number of the frame where the shot is released or the save/goal happens." },
          goal: { type: "boolean", description: "True only if the puck clearly ends up in the tracked goalie's net." },
          confidence: { type: "number", description: "0 to 1." },
        },
        required: ["frame", "goal", "confidence"],
        additionalProperties: false,
      },
    },
  },
  required: ["events"],
  additionalProperties: false,
};

const DETECT_PROMPT = `You are the first pass of a system that cuts hockey game film into shot moments for ONE tracked goalie. An admin watches every moment you flag and edits or deletes it, so your job is to catch ALL the action: a missed shot is a real failure, an extra flag costs the admin one click.

You get still frames about one to two seconds apart, in time order, with timestamps. The camera is often a wide, high view of the whole rink and may pan to follow play, so players and the puck are small.

Which net: the tracked goalie is identified by their team's jersey colour (given below when known). Watch the net that goalie defends. Teams switch ends between periods, so if the goalie in that colour is now at the other end, follow them there.

Flag every frame where, at that net, any of these is happening or just happened: a shot or shot attempt (wrist, slap, snap, backhand, tip, deflection, one-timer, wraparound, rebound); a player winding up, releasing, or following through toward the net; the puck moving toward or bouncing off the goalie; the goalie moving into a save, down, stretched, covering the puck, or recovering; a scramble or crowd at the crease; attacking players with the puck in the slot or circles facing the net; a whistle with players gathered at the net; a goal celebration or players skating away after a goal. Shots happen fast and may fall between two stills: if the play is in that zone and the next frame shows the aftermath (goalie down, puck loose, players crashing the net), flag the frame before it.

Do not flag: play clearly at the other end of the rink with no pressure on the tracked net, centre-ice faceoffs, line changes, empty ice, intermissions, warm-ups, replays or overlays. Several frames of the same sequence: flag one per distinct attempt (a shot and its rebound shot are two). Confidence: 0.2 when you suspect action, 0.5 when an attempt is likely, 0.8+ when a shot is clearly visible.`;

function cleanFrames(frames) {
  if (!Array.isArray(frames) || !frames.length || frames.length > MAX_FRAMES) return null;
  const out = [];
  for (const f of frames) {
    const data = f && typeof f.data === "string" ? f.data.replace(/^data:image\/jpeg;base64,/, "") : "";
    if (!data || data.length > MAX_FRAME_BASE64 || !/^[A-Za-z0-9+/=]+$/.test(data)) return null;
    const t = Number(f.t);
    out.push({ t: Number.isFinite(t) ? Math.max(0, Math.round(t * 100) / 100) : null, data });
  }
  return out;
}

function cleanTimes(times) {
  if (!Array.isArray(times) || !times.length || times.length > MAX_FRAMES) return null;
  const out = times.map(Number);
  return out.every(t => Number.isFinite(t) && t >= 0 && t < 6 * 3600) ? out : null;
}

// Frames for a stored video: the row is read with the caller's own
// token (RLS), its path must belong to its owner, then ffmpeg reads the
// requested moments over a short-lived signed URL.
async function framesFromStoredVideo(gameVideoId, times, width, accessToken) {
  const rows = await userSelect("game_videos", `id=eq.${encodeURIComponent(gameVideoId)}&select=*`, accessToken);
  const row = rows[0];
  if (!row || !(await storagePathIsTrusted(row))) {
    const err = new Error("Video not found.");
    err.status = 404;
    throw err;
  }
  const url = await getSignedUrl(
    r2Client(),
    new GetObjectCommand({ Bucket: process.env.R2_BUCKET_NAME, Key: row.storage_path }),
    { expiresIn: 60 * 15 }
  );
  return grabFrames(url, times, width);
}

function clamp(n, lo, hi) {
  const v = Number(n);
  if (!Number.isFinite(v)) return null;
  return Math.round(Math.max(lo, Math.min(hi, v)) * 10) / 10;
}

function pick(value, allowed, fallback) {
  return allowed.includes(value) ? value : fallback;
}

// The model's JSON is schema-constrained, but it's still input from
// outside this function: normalize every field before the browser
// writes it to the database.
function cleanShot(raw) {
  return {
    shot_detected: raw.shot_detected === true,
    outcome: raw.outcome === "goal" ? "goal" : "save",
    loc_x: clamp(raw.loc_x, -42.5, 42.5),
    loc_y: clamp(raw.loc_y, -11, 64),
    shot_type: (() => { const t = pick(raw.shot_type, SHOT_TYPES, "unknown"); return t === "unknown" ? null : t; })(),
    release_type: (() => { const r = pick(raw.release_type, RELEASE_TYPES, "unclear"); return r === "unclear" ? null : r; })(),
    rush: raw.rush === true,
    rebound: raw.rebound === true,
    screened: raw.screened === true,
    breakaway: raw.breakaway === true,
    cross_ice: raw.cross_ice === true,
    deflection: raw.deflection === true,
    reboundTag: pick(raw.rebound_control, REBOUND_TAGS, "skip"),
    confidence: clamp(raw.confidence, 0, 1) ?? 0,
    notes: String(raw.notes || "").replace(/\s+/g, " ").trim().slice(0, 240),
  };
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const { accessToken, frames, context, mode, gameVideoId, times, width } = req.body || {};
  const detect = mode === "detect";
  const fromVideo = gameVideoId !== undefined && gameVideoId !== null;
  const cleanedTimes = fromVideo ? cleanTimes(times) : null;
  let cleanedFrames = fromVideo ? null : cleanFrames(frames);

  if (!accessToken || (fromVideo ? !cleanedTimes : !cleanedFrames)) {
    res.status(400).json({ error: `Send between 1 and ${MAX_FRAMES} frames or timestamps.` });
    return;
  }

  if (fromVideo && (!r2Configured() || !ffmpegAvailable())) {
    // The browser falls back to reading frames itself on 501.
    res.status(501).json({ error: "This server can't read video frames.", code: "frames_unavailable" });
    return;
  }

  if (!claudeConfigured()) {
    res.status(503).json({ error: "AI clip tagging isn't set up yet (ANTHROPIC_API_KEY is missing)." });
    return;
  }

  try {
    const user = await verifyUser(accessToken);
    if (!user) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }
    if ((await callerRole(user.id, accessToken)) !== "admin") {
      res.status(403).json({ error: "AI clip tagging is available to admin accounts only." });
      return;
    }

    if (fromVideo) {
      const w = Math.max(240, Math.min(960, Number(width) || 640));
      try {
        cleanedFrames = await framesFromStoredVideo(gameVideoId, cleanedTimes, w, accessToken);
      } catch (error) {
        if (error.status === 404) {
          res.status(404).json({ error: "Video not found." });
          return;
        }
        throw error;
      }
      if (!cleanedFrames.length) {
        res.status(422).json({ error: "Couldn't read any frames at those times. The video may be shorter, or in a format the server can't decode." });
        return;
      }
    }

    const jersey = context && typeof context.goalieJersey === "string"
      ? context.goalieJersey.replace(/[^\w #-]/g, "").slice(0, 40)
      : "";

    if (detect) {
      const content = [];
      cleanedFrames.forEach((frame, i) => {
        content.push({ type: "text", text: `Frame ${i + 1}${frame.t !== null ? ` at ${frame.t}s` : ""}:` });
        content.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: frame.data } });
      });
      content.push({
        type: "text",
        text: (jersey ? `The tracked goalie's team wears ${jersey}. ` : "") + "List the shot events in these frames.",
      });

      const message = await claude().beta.messages.create({
        model: MODEL,
        max_tokens: 6000,
        betas: ["server-side-fallback-2026-07-01"],
        fallbacks: "default",
        output_config: {
          effort: "low",
          format: { type: "json_schema", schema: DETECT_SCHEMA },
        },
        system: DETECT_PROMPT,
        messages: [{ role: "user", content }],
      });

      if (message.stop_reason === "refusal") {
        res.status(200).json({ events: [] });
        return;
      }

      let parsed;
      try {
        parsed = JSON.parse(textOf(message));
      } catch (parseError) {
        console.error("Unparseable detect result:", message.stop_reason, parseError);
        res.status(502).json({ error: "The AI returned an unreadable answer for this stretch of video." });
        return;
      }

      const seen = new Set();
      const events = (Array.isArray(parsed.events) ? parsed.events : [])
        .map(e => {
          const i = Math.round(Number(e.frame)) - 1;
          const f = cleanedFrames[i];
          if (!f || f.t === null || seen.has(i)) return null;
          seen.add(i);
          return { t: f.t, goal: e.goal === true, confidence: clamp(e.confidence, 0, 1) ?? 0 };
        })
        .filter(Boolean)
        .sort((a, b) => a.t - b.t);

      res.status(200).json({
        events,
        model: message.model || MODEL,
        frameCount: cleanedFrames.length,
        // A few of the frames the AI looked at, so the admin can check
        // they're the right moments and clear enough to judge.
        preview: req.body && req.body.debug ? cleanedFrames.slice(0, 6).map(f => ({ t: f.t, data: f.data })) : undefined,
      });
      return;
    }

    const content = [];
    cleanedFrames.forEach((frame, i) => {
      content.push({ type: "text", text: `Frame ${i + 1}${frame.t !== null ? ` at ${frame.t}s` : ""}:` });
      content.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: frame.data } });
    });
    content.push({
      type: "text",
      text: jersey
        ? `The tracked goalie's team wears ${jersey}. Tag this clip.`
        : "Tag this clip.",
    });

    const message = await claude().beta.messages.create({
      model: MODEL,
      max_tokens: 8000,
      // Re-run a declined request on Anthropic's recommended fallback
      // model instead of failing the clip.
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      output_config: {
        effort: "medium",
        format: { type: "json_schema", schema: SHOT_SCHEMA },
      },
      system: SYSTEM_PROMPT,
      messages: [{ role: "user", content }],
    });

    if (message.stop_reason === "refusal") {
      res.status(422).json({ error: "The AI couldn't read this clip. Tag it by hand." });
      return;
    }

    let parsed;
    try {
      parsed = JSON.parse(textOf(message));
    } catch (parseError) {
      console.error("Unparseable clip analysis:", message.stop_reason, parseError);
      res.status(502).json({ error: "The AI returned an unreadable answer for this clip. Tag it by hand." });
      return;
    }

    res.status(200).json({ shot: cleanShot(parsed), model: message.model || MODEL });
  } catch (error) {
    sendServerError(res, error, "The AI couldn't analyze this clip right now.");
  }
}
