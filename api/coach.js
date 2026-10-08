// ============================================================
// AI COACH — serverless function
// ============================================================
// This runs on Vercel's server, not in the browser, so it's the
// only safe place to hold the Anthropic API key. It:
//   1. Takes the signed-in user's Supabase access token + their
//      question from the browser.
//   2. Uses that access token to pull the goalie's CURRENT
//      season's stats from Supabase (current = the season label
//      on their most recently dated game, detected automatically) — Row Level Security means it's physically
//      impossible for this to return anyone else's data, even
//      if someone tampered with the request.
//   3. Summarizes those stats into plain text.
//   4. Asks Claude to answer the question using that summary.
//   5. Returns the answer to the browser.
//
// Setup required (see the walkthrough that comes with this file):
//   - An Anthropic API key, set as the ANTHROPIC_API_KEY
//     environment variable in your Vercel project settings.
//     Get one at https://console.anthropic.com — this is a
//     separate account/billing from a claude.ai subscription.

import {
  verifyUser, userSelect, callerHasAccess, callerHasAiAccess, sendServerError,
} from "./_lib/supabase.js";
import { claude, claudeConfigured, textOf } from "./_lib/claude.js";

// Long enough for any real question; stops one request from turning
// into a very large (and very expensive) prompt.
const MAX_QUESTION_CHARS = 2000;

// Change this if Anthropic retires this model name.
const CLAUDE_MODEL = "claude-sonnet-5";


// "2026 Pre-Season", "2026 preseason" and "2026_pre_season" all
// normalize to "2026preseason", so small typing differences in the
// season label never split one season into two.
function normalizeSeason(value) {
  return String(value ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "");
}

// The current season is whatever season label is on the goalie's
// most recent game (by date, then by id as a tie-breaker). No
// hardcoded season to update: log a game under a new season label
// and the coach switches to it automatically.
function findCurrentSeason(games) {
  const withSeason = games.filter(g => normalizeSeason(g.season));
  if (withSeason.length === 0) return null;

  const sorted = withSeason.slice().sort((a, b) => {
    const da = a.date ? Date.parse(a.date) : -Infinity;
    const db = b.date ? Date.parse(b.date) : -Infinity;
    if (db !== da) return db - da;
    return num(b.id) - num(a.id);
  });

  return String(sorted[0].season).trim();
}

function num(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

function pct(numerator, denominator) {
  if (!denominator) return null;
  return Math.round((numerator / denominator) * 1000) / 10; // one decimal
}

function supabaseQuery(table, accessToken) {
  return userSelect(table, "select=*", accessToken);
}


function buildStatsSummary({ games, periodStats, shots, reboundControls, puckPlaying }) {

  const currentSeason = findCurrentSeason(games);

  if (!currentSeason) {
    return "No games logged yet.";
  }

  const target = normalizeSeason(currentSeason);
  const seasonGames = games.filter(g => normalizeSeason(g.season) === target);
  const seasonGameIds = new Set(seasonGames.map(g => String(g.id)));

  const seasonPeriods = periodStats.filter(p => seasonGameIds.has(String(p.game_id)));
  const seasonShots = shots.filter(s => seasonGameIds.has(String(s.game_id)));
  const seasonRebounds = reboundControls.filter(r => seasonGameIds.has(String(r.game_id)));
  const seasonPuck = puckPlaying.filter(p => seasonGameIds.has(String(p.game_id)));

  const gamesPlayed = seasonGames.length;
  const wins = seasonGames.filter(g => g.result === "W").length;
  const losses = seasonGames.filter(g => g.result === "L").length;
  const otLosses = seasonGames.filter(g => g.result === "OTL").length;

  const totalShotsAgainst = seasonGames.reduce((sum, g) => sum + num(g.shots_against), 0);
  const totalSaves = seasonGames.reduce((sum, g) => sum + num(g.saves), 0);
  const totalGoalsAgainst = seasonGames.reduce((sum, g) => sum + num(g.goals_against), 0);
  // Scale each game to 60 minutes using its regulation length (game_length),
  // so short-game leagues (e.g. 34-minute games) get a fair GAA.
  const totalMinutes = seasonGames.reduce((sum, g) => {
    const len = num(g.game_length) > 0 ? num(g.game_length) : 60;
    return sum + num(g.minutes_played) * 60 / len;
  }, 0);
  const shutouts = seasonGames.filter(g => g.shutout).length;

  const savePct = pct(totalSaves, totalShotsAgainst);
  const gaa = totalMinutes > 0 ? Math.round((totalGoalsAgainst / (totalMinutes / 60)) * 100) / 100 : null;

  const lines = [];

  lines.push(`Season: ${currentSeason}`);
  lines.push(`Record: ${wins}-${losses}-${otLosses} across ${gamesPlayed} games`);
  lines.push(`Shots faced: ${totalShotsAgainst}, Saves: ${totalSaves}, Goals against: ${totalGoalsAgainst}`);
  lines.push(`Save percentage: ${savePct !== null ? savePct + "%" : "n/a"}`);
  lines.push(`Goals against average: ${gaa !== null ? gaa : "n/a"}`);
  lines.push(`Shutouts: ${shutouts}`);

  // Period breakdown
  const periodGroups = {};
  seasonPeriods.forEach(p => {
    const key = String(p.period || "?");
    if (!periodGroups[key]) periodGroups[key] = { shots: 0, saves: 0, goals: 0 };
    periodGroups[key].shots += num(p.shots_against);
    periodGroups[key].saves += num(p.saves);
    periodGroups[key].goals += num(p.goals_against);
  });

  const periodLines = Object.keys(periodGroups).sort().map(key => {
    const g = periodGroups[key];
    const sv = pct(g.saves, g.shots);
    return `Period ${key}: ${g.shots} shots, ${sv !== null ? sv + "% save rate" : "n/a"}, ${g.goals} goals against`;
  });

  if (periodLines.length > 0) {
    lines.push("Period breakdown:");
    lines.push(...periodLines.map(l => "  - " + l));
  }

  // Shot situational breakdown
  const flagGroups = {
    rush: seasonShots.filter(s => s.rush),
    rebound: seasonShots.filter(s => s.rebound),
    screened: seasonShots.filter(s => s.screened),
    breakaway: seasonShots.filter(s => s.breakaway),
    cross_ice: seasonShots.filter(s => s.cross_ice),
    deflection: seasonShots.filter(s => s.deflection)
  };

  const flagLines = Object.entries(flagGroups)
    .filter(([, arr]) => arr.length > 0)
    .map(([flag, arr]) => {
      const goals = arr.filter(s => s.outcome === "goal").length;
      const sv = pct(arr.length - goals, arr.length);
      return `${flag}: ${arr.length} shots, ${sv !== null ? sv + "% save rate" : "n/a"}`;
    });

  if (flagLines.length > 0) {
    lines.push("Shot situation breakdown:");
    lines.push(...flagLines.map(l => "  - " + l));
  }

  // Location breakdown
  const locationGroups = {};
  seasonShots.forEach(s => {
    const key = s.location || "unspecified";
    if (!locationGroups[key]) locationGroups[key] = { total: 0, goals: 0 };
    locationGroups[key].total++;
    if (s.outcome === "goal") locationGroups[key].goals++;
  });

  const locationLines = Object.entries(locationGroups).map(([loc, g]) => {
    const sv = pct(g.total - g.goals, g.total);
    return `${loc}: ${g.total} shots, ${sv !== null ? sv + "% save rate" : "n/a"}`;
  });

  if (locationLines.length > 0) {
    lines.push("Shot location breakdown:");
    lines.push(...locationLines.map(l => "  - " + l));
  }

  // Rebound control tendencies (season totals)
  if (seasonRebounds.length > 0) {
    const totals = {};
    [
      "glove_caught", "glove_rebound", "glove_goal",
      "blocker_good", "blocker_bad", "blocker_goal",
      "midsection_good", "midsection_bad", "midsection_goal",
      "pad_stick_good", "pad_stick_bad", "pad_stick_goal"
    ].forEach(key => {
      totals[key] = seasonRebounds.reduce((sum, r) => sum + num(r[key]), 0);
    });

    lines.push("Rebound control totals this season:");
    lines.push(`  - Glove: ${totals.glove_caught} caught clean, ${totals.glove_rebound} gave up a rebound, ${totals.glove_goal} led to a goal`);
    lines.push(`  - Blocker: ${totals.blocker_good} good, ${totals.blocker_bad} bad, ${totals.blocker_goal} led to a goal`);
    lines.push(`  - Midsection: ${totals.midsection_good} good, ${totals.midsection_bad} bad, ${totals.midsection_goal} led to a goal`);
    lines.push(`  - Pad/Stick: ${totals.pad_stick_good} good, ${totals.pad_stick_bad} bad, ${totals.pad_stick_goal} led to a goal`);
  }

  // Puck playing
  if (seasonPuck.length > 0) {
    const rimsFaced = seasonPuck.reduce((sum, p) => sum + num(p.rims_faced), 0);
    const rimsStopped = seasonPuck.reduce((sum, p) => sum + num(p.rims_stopped), 0);
    const passAttempts = seasonPuck.reduce((sum, p) => sum + num(p.pass_attempts), 0);
    const passesCompleted = seasonPuck.reduce((sum, p) => sum + num(p.passes_completed), 0);

    lines.push("Puck playing this season:");
    lines.push(`  - Rims faced: ${rimsFaced}, stopped: ${rimsStopped} (${pct(rimsStopped, rimsFaced) ?? "n/a"}%)`);
    lines.push(`  - Pass attempts: ${passAttempts}, completed: ${passesCompleted} (${pct(passesCompleted, passAttempts) ?? "n/a"}%)`);

    // Breakdown by rim side/height and pass type (only the kinds with data)
    const sumKey = key => seasonPuck.reduce((sum, p) => sum + num(p[key]), 0);

    [["forehand_ice", "forehand, on the ice"], ["backhand_ice", "backhand, on the ice"],
     ["forehand_high", "forehand, up high"], ["backhand_high", "backhand, up high"]].forEach(([k, label]) => {
      const faced = sumKey("rims_faced_" + k);
      const stopped = sumKey("rims_stopped_" + k);
      if (faced > 0) {
        lines.push(`  - Rims ${label}: ${stopped}/${faced} stopped (${pct(stopped, faced) ?? "n/a"}%)`);
      }
    });

    [["forehand", "forehand"], ["backhand", "backhand"], ["stretch", "stretch"]].forEach(([k, label]) => {
      const attempts = sumKey("pass_attempts_" + k);
      const completed = sumKey("passes_completed_" + k);
      if (attempts > 0) {
        lines.push(`  - ${label[0].toUpperCase() + label.slice(1)} passes: ${completed}/${attempts} completed (${pct(completed, attempts) ?? "n/a"}%)`);
      }
    });
  }

  return lines.join("\n");

}






export default async function handler(req, res) {

  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const { accessToken, question, goalieId, viewerRole } = req.body || {};

  if (!accessToken || typeof question !== "string" || !question.trim()) {
    res.status(400).json({ error: "Missing accessToken or question." });
    return;
  }

  if (question.length > MAX_QUESTION_CHARS) {
    res.status(400).json({ error: `Please keep questions under ${MAX_QUESTION_CHARS} characters.` });
    return;
  }

  if (typeof goalieId !== "string" || !/^[0-9a-f-]{36}$/i.test(goalieId)) {
    res.status(400).json({ error: "Missing goalieId." });
    return;
  }

  if (!claudeConfigured()) {
    res.status(503).json({ error: "AI Coach is being finalized and will be available soon." });
    return;
  }

  try {

    if (!(await verifyUser(accessToken))) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }
    if (!(await callerHasAccess(accessToken))) {
      res.status(402).json({ error: "Your GoalieIQ access isn't active." });
      return;
    }
    if (!(await callerHasAiAccess(accessToken))) {
      res.status(402).json({ error: "AI Coach and AI game reports are part of Goalie Plus.", upgrade: true });
      return;
    }

    const [gamesAll, periodStatsAll, shotsAll, reboundControlsAll, puckPlayingAll] = await Promise.all([
      supabaseQuery("Games", accessToken),
      supabaseQuery("Period Stats", accessToken),
      supabaseQuery("Shots", accessToken),
      supabaseQuery("goalierebound_control", accessToken).catch(() => []),
      supabaseQuery("puck_playing", accessToken).catch(() => [])
    ]);

    // RLS already limited the above to rows this caller is allowed to
    // see at all (their own, OR an assigned goalie's if they're a
    // coach, OR everything if admin). This filter narrows that down
    // to the ONE goalie being asked about -- without it, a coach with
    // more than one assigned goalie would get their stats silently
    // blended together in the same summary.
    const belongsToGoalie = (row) => row.user_id === goalieId;

    const games = gamesAll.filter(belongsToGoalie);
    const periodStats = periodStatsAll.filter(belongsToGoalie);
    const shots = shotsAll.filter(belongsToGoalie);
    const reboundControls = reboundControlsAll.filter(belongsToGoalie);
    const puckPlaying = puckPlayingAll.filter(belongsToGoalie);

    const statsSummary = buildStatsSummary({ games, periodStats, shots, reboundControls, puckPlaying });

    const systemPrompt =
      viewerRole === "coach"
        ? "You are an assistant helping a hockey coach review one of their assigned goalies' " +
          "performance in their current season. Answer the coach's questions using only the stats summary " +
          "below. Frame answers for a coach making training decisions: what to focus on this " +
          "week, what's improving or declining, and what situations are creating the most goals " +
          "against. Be specific and reference actual numbers from the summary. If the summary " +
          "doesn't contain enough information to answer confidently, say so plainly rather than " +
          "guessing.\n\n" +
          "STATS SUMMARY:\n" + statsSummary
        : "You are a goaltending assistant. You answer a goalie's questions about their current " +
          "season's performance using only the stats summary below. Be specific and reference actual " +
          "numbers from the summary. If the summary doesn't contain enough information to answer " +
          "confidently, say so plainly rather than guessing. Keep answers focused and practical.\n\n" +
          "STATS SUMMARY:\n" + statsSummary;

    const message = await claude().messages.create({
      model: CLAUDE_MODEL,
      max_tokens: 2000,
      system: systemPrompt,
      messages: [
        { role: "user", content: question.trim() }
      ]
    });

    const answerText =
      message.stop_reason === "refusal"
        ? "I can't help with that one. Try asking about this season's stats."
        : (textOf(message) || "No response generated.");

    res.status(200).json({ answer: answerText });

  } catch (error) {

    sendServerError(res, error, "AI Coach couldn't answer right now. Please try again.");

  }

}
