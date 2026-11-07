// ============================================================
// ML DATASET EXPORT — tagged games on the site -> local training data
// ============================================================
// Read-only. Pulls every game that has tagged shots, the shots
// themselves, and the video each shot points at, and writes a dataset
// the training code can read without touching Supabase again.
//
//   node --env-file=.env ml/export-dataset.mjs            # labels only
//   node --env-file=.env ml/export-dataset.mjs --clips    # + one MP4 per shot
//   node ml/export-dataset.mjs --from-csv ml/data/csv     # no service key:
//     reads Games.csv, Shots.csv, game_videos.csv, video_shot_drafts.csv
//     downloaded from the Supabase SQL editor (see ml/export-queries.sql)
//
// .env needs (same names as Vercel):
//   SUPABASE_SERVICE_ROLE_KEY                      (always)
//   R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET_NAME
//                                                  (only with --clips)
//
// Output (ml/data/, git-ignored: it is goalies' film and stats):
//   raw/<table>.json   untouched rows, for anything not mapped below
//   shots.jsonl        one labelled shot per line, with where to find it
//                      in video (full game + time, or its own clip)
//   games.jsonl        one game per line: its video, period marks and
//                      every shot time (what shot *detection* trains on)
//   summary.md         counts, video coverage, label balance
//   clips/<shot>.mp4   with --clips: the shot's window, 640px, no audio
//
// How a shot finds its video:
//   * Published from Video Review: Shots.game_video_id is the full game
//     and clip_start/end sit 4 s before / 3 s after the shot, so the shot
//     time is clip_start + 4 (or the matching video_shot_drafts row).
//   * Clip attached by hand: game_video_id is a short clip of its own,
//     clip_start 0. The shot happens somewhere inside it.

import fs from "fs";
import path from "path";
import { spawn } from "child_process";
import { fileURLToPath } from "url";
import { GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import ffmpegPath from "ffmpeg-static";
import { SUPABASE_URL, r2Configured, r2Client } from "../api/_lib/supabase.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(HERE, "data");
const WANT_CLIPS = process.argv.includes("--clips");
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const CSV_DIR = (() => {
  const i = process.argv.indexOf("--from-csv");
  return i >= 0 ? path.resolve(process.argv[i + 1] || path.join(OUT, "csv")) : null;
})();

// Review clips publish 4 s before / 3 s after the shot (approveReview).
const CLIP_BEFORE = 4;
const CLIP_AFTER = 3;
// A video longer than this is treated as full-game film, not a shot clip.
const FULL_GAME_MIN_SECONDS = 180;

const LABEL_FIELDS = [
  "outcome", "period", "strength", "location", "loc_x", "loc_y",
  "shot_type", "release_type", "rebound_tag",
  "rush", "rebound", "screened", "breakaway", "cross_ice", "deflection",
];

if (!KEY && !CSV_DIR) {
  console.error("Missing SUPABASE_SERVICE_ROLE_KEY. Put it in .env and run with: node --env-file=.env ml/export-dataset.mjs");
  process.exit(1);
}
if (WANT_CLIPS && !r2Configured()) {
  console.error("--clips needs R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY and R2_BUCKET_NAME in .env.");
  process.exit(1);
}

// ---- Supabase (service role, read-only GETs, paged) ----

async function selectAll(table, query = "select=*") {
  const rows = [];
  const page = 1000;
  for (let from = 0; ; from += page) {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/${encodeURIComponent(table)}?${query}`, {
      headers: {
        apikey: KEY,
        Authorization: `Bearer ${KEY}`,
        Range: `${from}-${from + page - 1}`,
        "Range-Unit": "items",
      },
    });
    if (!res.ok) throw new Error(`GET ${table} failed: ${res.status} ${await res.text()}`);
    const batch = await res.json();
    rows.push(...batch);
    if (batch.length < page) return rows;
  }
}

const shotId = s => s.shot_id ?? s.id;
const num = v => (v === null || v === undefined || v === "" ? null : Number(v));

// ---- Build ----

async function main() {
  fs.mkdirSync(path.join(OUT, "raw"), { recursive: true });

  let games, shots, videos, drafts;
  if (CSV_DIR) {
    console.log(`Reading CSVs from ${CSV_DIR}…`);
    [games, shots, videos, drafts] = ["Games", "Shots", "game_videos", "video_shot_drafts"]
      .map((t, i) => readCsvTable(t, i === 3));
  } else {
    console.log("Reading Supabase…");
    [games, shots, videos, drafts] = await Promise.all([
      selectAll("Games"),
      selectAll("Shots"),
      selectAll("game_videos"),
      selectAll("video_shot_drafts").catch(() => []),
    ]);
  }
  for (const [name, rows] of Object.entries({ Games: games, Shots: shots, game_videos: videos, video_shot_drafts: drafts })) {
    fs.writeFileSync(path.join(OUT, "raw", `${name}.json`), JSON.stringify(rows, null, 1));
  }

  const videoById = new Map(videos.map(v => [String(v.id), v]));
  const draftsByVideo = groupBy(drafts, d => String(d.game_video_id));
  for (const list of draftsByVideo.values()) list.sort((a, b) => Number(a.t_seconds) - Number(b.t_seconds));

  // Full-game film: has Video Review drafts, or is long. Short videos are
  // per-shot clips (one game_videos row per shot, no duration).
  const isFilm = v =>
    !!v && (draftsByVideo.has(String(v.id)) || (num(v.duration_seconds) ?? 0) >= FULL_GAME_MIN_SECONDS);

  // ---- Pair each game's published shots with its Video Review drafts ----
  // Approval writes Shots in draft time order, so shot_id order = draft
  // order. A game's film can be split in parts (parent_video_id); parts
  // are concatenated by id. When counts differ (a shot added or removed
  // after publishing), align on outcome/type/location/strength instead.
  const shotsByGame = groupBy(shots, s => String(s.game_id));
  const filmByGame = new Map();
  for (const v of videos) {
    if (v.game_id == null || !draftsByVideo.has(String(v.id))) continue;
    const k = String(v.game_id);
    if (!filmByGame.has(k)) filmByGame.set(k, []);
    filmByGame.get(k).push(v);
  }
  const draftForShot = new Map();   // shot id -> { draft, video }
  const pairing = { exact: 0, aligned: 0, unpaired: 0 };
  for (const [gameId, film] of filmByGame) {
    film.sort((a, b) => Number(a.id) - Number(b.id));
    const ds = film.flatMap(v => draftsByVideo.get(String(v.id)).map(d => ({ draft: d, video: v })));
    const ss = (shotsByGame.get(gameId) || []).slice().sort((a, b) => Number(shotId(a)) - Number(shotId(b)));
    const pairs = ss.length === ds.length ? ss.map((s, i) => [s, ds[i]]) : align(ss, ds);
    if (ss.length === ds.length) pairing.exact += pairs.length; else pairing.aligned += pairs.length;
    pairing.unpaired += ss.length - pairs.length;
    for (const [s, d] of pairs) draftForShot.set(String(shotId(s)), d);
  }

  // ---- shots.jsonl ----
  const shotRows = [];
  for (const s of shots) {
    const v = s.game_video_id != null ? videoById.get(String(s.game_video_id)) : null;
    const start = num(s.clip_start_seconds);
    const end = num(s.clip_end_seconds);
    const paired = draftForShot.get(String(shotId(s)));

    // Where the shot is in full-game film (what detection trains on).
    let film = null;
    if (paired) {
      film = { video_id: paired.video.id, storage_path: paired.video.storage_path, t_seconds: Number(paired.draft.t_seconds), time_source: "draft" };
    } else if (v && isFilm(v) && (start != null || end != null)) {
      film = { video_id: v.id, storage_path: v.storage_path, t_seconds: start != null ? start + CLIP_BEFORE : end - CLIP_AFTER, time_source: "clip_window" };
    }
    // The shot's own clip file, if it has one (what tagging trains on).
    const clip = v && !isFilm(v) ? { video_id: v.id, storage_path: v.storage_path, start: start ?? 0, end } : null;

    const labels = {};
    for (const f of LABEL_FIELDS) labels[f] = s[f] ?? null;

    shotRows.push({
      shot_id: shotId(s),
      game_id: s.game_id,
      user_id: s.user_id,
      labels,
      xg: num(s.xg),
      ai_tagged: !!s.ai_tagged,
      ai_reviewed: !!s.ai_reviewed_at,
      film,
      clip,
    });
  }
  writeJsonl("shots.jsonl", shotRows);

  // ---- games.jsonl ----
  const rowsByGame = groupBy(shotRows, r => String(r.game_id));
  const gameRows = [];
  for (const g of games) {
    const gs = rowsByGame.get(String(g.id)) || [];
    if (!gs.length) continue;
    const film = (filmByGame.get(String(g.id)) || []).slice().sort((a, b) => Number(a.id) - Number(b.id));
    gameRows.push({
      game_id: g.id,
      user_id: g.user_id,
      date: g.date ?? null,
      team: g.team ?? null,
      opponent: g.opponent ?? null,
      shots: gs.length,
      goals: gs.filter(r => r.labels.outcome === "goal").length,
      film: film.map(v => ({
        video_id: v.id,
        parent_video_id: v.parent_video_id ?? null,
        storage_path: v.storage_path,
        duration_seconds: num(v.duration_seconds),
        period_marks: v.period_marks || {},
        team_jersey_color: v.team_jersey_color ?? null,
        // Every approved shot moment in this file, in seconds.
        shot_times: draftsByVideo.get(String(v.id)).map(d => Number(d.t_seconds)),
        goal_times: draftsByVideo.get(String(v.id)).filter(d => d.outcome === "goal").map(d => Number(d.t_seconds)),
      })),
      film_shots: gs.filter(r => r.film).length,
      clip_shots: gs.filter(r => r.clip).length,
      no_video_shots: gs.filter(r => !r.film && !r.clip).length,
    });
  }
  gameRows.sort((a, b) => String(a.date).localeCompare(String(b.date)));
  writeJsonl("games.jsonl", gameRows);

  // ---- clips ----
  let clipStats = null;
  if (WANT_CLIPS) clipStats = await downloadClips(shotRows);

  // ---- summary ----
  const summary = buildSummary(gameRows, shotRows, clipStats, pairing);
  fs.writeFileSync(path.join(OUT, "summary.md"), summary);
  console.log("\n" + summary);
  console.log(`Wrote ${path.relative(process.cwd(), OUT)}/`);
}

// ---- Clips: cut each shot's window straight from R2 (no full download) ----

async function downloadClips(shotRows) {
  const dir = path.join(OUT, "clips");
  fs.mkdirSync(dir, { recursive: true });
  const s3 = r2Client();
  const urlCache = new Map();
  const signed = async key => {
    if (!urlCache.has(key)) {
      urlCache.set(key, await getSignedUrl(s3, new GetObjectCommand({ Bucket: process.env.R2_BUCKET_NAME, Key: key }), { expiresIn: 6 * 3600 }));
    }
    return urlCache.get(key);
  };

  // Prefer the film window (same framing for every shot, exact time);
  // fall back to the shot's own clip file.
  const jobs = shotRows.filter(r => r.film || r.clip);
  let done = 0, skipped = 0, failed = 0, next = 0;

  async function worker() {
    while (next < jobs.length) {
      const r = jobs[next++];
      const file = path.join(dir, `${r.shot_id}.mp4`);
      if (fs.existsSync(file) && fs.statSync(file).size > 0) { skipped++; continue; }
      let key, start, end;
      if (r.film) {
        key = r.film.storage_path;
        start = Math.max(0, r.film.t_seconds - CLIP_BEFORE);
        end = r.film.t_seconds + CLIP_AFTER;
      } else {
        key = r.clip.storage_path;
        start = r.clip.start ?? 0;
        end = r.clip.end ?? start + 30;
      }
      try {
        await cut(await signed(key), start, end, file);
        done++;
      } catch (e) {
        failed++;
        console.warn(`shot ${r.shot_id}: ${e.message}`);
        fs.rmSync(file, { force: true });
      }
      process.stdout.write(`\rclips: ${done} new, ${skipped} already there, ${failed} failed / ${jobs.length}`);
    }
  }
  await Promise.all(Array.from({ length: 4 }, worker));
  process.stdout.write("\n");
  return { done, skipped, failed, total: jobs.length };
}

function cut(url, start, end, file) {
  return new Promise((resolve, reject) => {
    const args = [
      "-hide_banner", "-loglevel", "error", "-y",
      "-ss", String(start), "-i", url, "-t", String(Math.max(0.5, end - start)),
      "-an", "-vf", "scale=640:-2", "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
      "-movflags", "+faststart", file,
    ];
    const p = spawn(ffmpegPath, args);
    let err = "";
    p.stderr.on("data", d => (err += d));
    p.on("error", reject);
    p.on("close", code => (code === 0 ? resolve() : reject(new Error(err.trim().split("\n").pop() || `ffmpeg exit ${code}`))));
  });
}

// ---- Summary ----

function buildSummary(gameRows, shotRows, clipStats, pairing) {
  const gameIds = new Set(gameRows.map(g => String(g.game_id)));
  const inGames = shotRows.filter(r => gameIds.has(String(r.game_id)));
  const film = inGames.filter(r => r.film);
  const clip = inGames.filter(r => r.clip);
  const either = inGames.filter(r => r.film || r.clip);
  const none = inGames.filter(r => !r.film && !r.clip);
  const filmGames = gameRows.filter(g => g.film.length);
  const filmHours = filmGames.reduce((h, g) => h + g.film.filter(v => !v.parent_video_id).reduce((s, v) => s + (v.duration_seconds || 0), 0), 0) / 3600;
  const goalies = new Set(gameRows.map(g => g.user_id));

  const lines = [
    "# GoalieIQ ML dataset",
    "",
    `Exported ${new Date().toISOString()}`,
    "",
    "## Coverage",
    "",
    `- Games with tagged shots: **${gameRows.length}** (${goalies.size} goalies)`,
    `- Tagged shots: **${inGames.length}** (${inGames.filter(r => r.labels.outcome === "goal").length} goals)`,
    `- Shots with video of any kind (usable for *tagging*): **${either.length}**`,
    `  - located in full-game film at an exact time: ${film.length} (${film.filter(r => r.film.time_source === "draft").length} via Video Review drafts)`,
    `  - with their own clip file: ${clip.length}`,
    `  - no video: ${none.length}`,
    `- Games with full film + every shot time (usable for shot *detection*): **${filmGames.length}** (~${filmHours.toFixed(0)} h of film, upload length incl. warm-up)`,
    `- Draft pairing: ${pairing.exact} shots by exact order, ${pairing.aligned} by tag alignment, ${pairing.unpaired} left unpaired`,
    `- AI-tagged shots: ${inGames.filter(r => r.ai_tagged).length} (${inGames.filter(r => r.ai_tagged && r.ai_reviewed).length} reviewed by a human)`,
  ];
  if (clipStats) {
    lines.push(`- Clips: ${clipStats.done} cut now, ${clipStats.skipped} already on disk, ${clipStats.failed} failed (of ${clipStats.total})`);
  }

  lines.push("", "## Label balance", "", "Fields a model would learn. `—` = not tagged.", "");
  for (const f of LABEL_FIELDS) {
    if (f === "loc_x" || f === "loc_y" || f === "period") continue;
    const counts = new Map();
    for (const r of inGames) {
      const k = r.labels[f] === null || r.labels[f] === undefined || r.labels[f] === "" ? "—" : String(r.labels[f]);
      counts.set(k, (counts.get(k) || 0) + 1);
    }
    const parts = [...counts.entries()].sort((a, b) => b[1] - a[1]).map(([k, n]) => `${k} ${n}`);
    lines.push(`- **${f}**: ${parts.join(", ")}`);
  }
  const located = inGames.filter(r => r.labels.loc_x != null && r.labels.loc_y != null).length;
  lines.push(`- **loc_x / loc_y**: ${located} of ${inGames.length} shots have a rink position`);

  lines.push("", "## Games", "", "| Date | Team | Opponent | Shots | Goals | Film parts | Shots in film | Clip shots | No video |", "|---|---|---|---|---|---|---|---|---|");
  for (const g of gameRows) {
    lines.push(`| ${g.date ?? "?"} | ${g.team ?? "?"} | ${g.opponent ?? "?"} | ${g.shots} | ${g.goals} | ${g.film.length || "—"} | ${g.film_shots} | ${g.clip_shots} | ${g.no_video_shots} |`);
  }
  return lines.join("\n") + "\n";
}

// ---- Shot <-> draft alignment when counts differ ----

// Longest common subsequence on the tags a published shot copies from
// its draft. Both lists are in time order, so order is kept.
function align(shots, drafts) {
  const key = x => [x.outcome, x.shot_type, x.location, x.strength].map(v => v ?? "").join("|");
  const a = shots.map(key), b = drafts.map(d => key(d.draft));
  const n = a.length, m = b.length;
  const dp = Array.from({ length: n + 1 }, () => new Int32Array(m + 1));
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  const pairs = [];
  for (let i = 0, j = 0; i < n && j < m; ) {
    if (a[i] === b[j]) { pairs.push([shots[i], drafts[j]]); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) i++;
    else j++;
  }
  return pairs;
}

// ---- CSV input (Supabase SQL editor "Download CSV") ----

// Finds <table>.csv in CSV_DIR (also accepts names with the table in
// them, e.g. "Supabase Snippet Shots.csv") and turns each row into the
// same shape the REST API returns: "" -> null, true/false -> booleans,
// numbers -> numbers, JSON objects/arrays parsed.
function readCsvTable(table, optional) {
  const files = fs.existsSync(CSV_DIR) ? fs.readdirSync(CSV_DIR).filter(f => f.toLowerCase().endsWith(".csv")) : [];
  const want = table.toLowerCase();
  const file =
    files.find(f => f.toLowerCase() === `${want}.csv`) ||
    files.find(f => f.toLowerCase().replace(/[^a-z_]/g, "").includes(want.replace(/[^a-z_]/g, "")));
  if (!file) {
    if (optional) return [];
    throw new Error(`No ${table}.csv in ${CSV_DIR}`);
  }
  const rows = parseCsv(fs.readFileSync(path.join(CSV_DIR, file), "utf8"));
  const header = rows.shift() || [];
  return rows
    .filter(r => r.length > 1 || (r[0] ?? "") !== "")
    .map(r => Object.fromEntries(header.map((h, i) => [h, csvValue(r[i])])));
}

function csvValue(v) {
  // The SQL editor writes SQL NULL as the bare word null.
  if (v === undefined || v === "" || v === "NULL" || v === "null") return null;
  if (v === "true") return true;
  if (v === "false") return false;
  if (/^-?\d+(\.\d+)?(e-?\d+)?$/i.test(v) && v.length < 16) return Number(v);
  if ((v.startsWith("{") && v.endsWith("}")) || (v.startsWith("[") && v.endsWith("]"))) {
    try { return JSON.parse(v); } catch { /* keep text */ }
  }
  return v;
}

// RFC 4180: quoted fields, "" escapes, newlines inside quotes.
function parseCsv(text) {
  const rows = [];
  let row = [], field = "", quoted = false;
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; } else quoted = false;
      } else field += c;
    } else if (c === '"') quoted = true;
    else if (c === ",") { row.push(field); field = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(field); rows.push(row); row = []; field = "";
    } else field += c;
  }
  if (field !== "" || row.length) { row.push(field); rows.push(row); }
  return rows;
}

// ---- helpers ----

function writeJsonl(name, rows) {
  fs.writeFileSync(path.join(OUT, name), rows.map(r => JSON.stringify(r)).join("\n") + "\n");
}

function groupBy(rows, key) {
  const m = new Map();
  for (const r of rows) {
    const k = key(r);
    if (!m.has(k)) m.set(k, []);
    m.get(k).push(r);
  }
  return m;
}

main().catch(e => {
  console.error(e.message);
  process.exit(1);
});
