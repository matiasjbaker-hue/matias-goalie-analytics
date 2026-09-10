// ============================================================
// AI COACH — serverless function
// ============================================================
// This runs on Vercel's server, not in the browser, so it's the
// only safe place to hold the Anthropic API key. It:
//   1. Takes the signed-in user's Supabase access token + their
//      question from the browser.
//   2. Uses that access token to pull THIS SEASON's stats from
//      Supabase — Row Level Security means it's physically
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

const SUPABASE_URL = "https://iiuqxxrrruvwvfehrzic.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ";
const CURRENT_SEASON = "2026 preseason";

// Change this if Anthropic retires this model name — check
// https://docs.claude.com for current model strings.
const CLAUDE_MODEL = "claude-sonnet-5";


function normalizeSeason(value) {
  return String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/[_-]/g, " ")
    .replace(/\s+/g, " ");
}

function isCurrentSeason(value) {
  const s = normalizeSeason(value);
  const target = normalizeSeason(CURRENT_SEASON);
  return s === target;
}

function num(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

function pct(numerator, denominator) {
  if (!denominator) return null;
  return Math.round((numerator / denominator) * 1000) / 10; // one decimal
}

async function supabaseQuery(table, accessToken) {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/${encodeURIComponent(table)}?select=*`,
    {
      headers: {
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${accessToken}`
      }
    }
  );

  if (!res.ok) {
    throw new Error(`Supabase error ${res.status} on ${table}`);
  }

  const data = await res.json();
  return Array.isArray(data) ? data : [];
}


function buildStatsSummary({ games, periodStats, shots, reboundControls, puckPlaying }) {

  const seasonGames = games.filter(g => isCurrentSeason(g.season));
  const seasonGameIds = new Set(seasonGames.map(g => String(g.id)));

  const seasonPeriods = periodStats.filter(p => seasonGameIds.has(String(p.game_id)));
  const seasonShots = shots.filter(s => seasonGameIds.has(String(s.game_id)));
  const seasonRebounds = reboundControls.filter(r => seasonGameIds.has(String(r.game_id)));
  const seasonPuck = puckPlaying.filter(p => seasonGameIds.has(String(p.game_id)));

  if (seasonGames.length === 0) {
    return "No games logged yet this season.";
  }

  const gamesPlayed = seasonGames.length;
  const wins = seasonGames.filter(g => g.result === "W").length;
  const losses = seasonGames.filter(g => g.result === "L").length;
  const otLosses = seasonGames.filter(g => g.result === "OTL").length;

  const totalShotsAgainst = seasonGames.reduce((sum, g) => sum + num(g.shots_against), 0);
  const totalSaves = seasonGames.reduce((sum, g) => sum + num(g.saves), 0);
  const totalGoalsAgainst = seasonGames.reduce((sum, g) => sum + num(g.goals_against), 0);
  const totalMinutes = seasonGames.reduce((sum, g) => sum + num(g.minutes_played), 0);
  const shutouts = seasonGames.filter(g => g.shutout).length;

  const savePct = pct(totalSaves, totalShotsAgainst);
  const gaa = totalMinutes > 0 ? Math.round((totalGoalsAgainst / (totalMinutes / 60)) * 100) / 100 : null;

  const lines = [];

  lines.push(`Season: ${CURRENT_SEASON}`);
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
  }

  return lines.join("\n");

}


export default async function handler(req, res) {

  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const { accessToken, question } = req.body || {};

  if (!accessToken || !question) {
    res.status(400).json({ error: "Missing accessToken or question." });
    return;
  }

  if (!process.env.ANTHROPIC_API_KEY) {
    res.status(500).json({ error: "Server is not configured with an ANTHROPIC_API_KEY." });
    return;
  }

  try {

    const [games, periodStats, shots, reboundControls, puckPlaying] = await Promise.all([
      supabaseQuery("Games", accessToken),
      supabaseQuery("Period Stats", accessToken),
      supabaseQuery("Shots", accessToken),
      supabaseQuery("goalierebound_control", accessToken).catch(() => []),
      supabaseQuery("puck_playing", accessToken).catch(() => [])
    ]);

    if (games.length === 0 && periodStats.length === 0 && shots.length === 0) {
      // Either a bad/expired token (RLS returned nothing) or genuinely no data.
      // Either way, we don't error — we just tell the model there's nothing to work with.
    }

    const statsSummary = buildStatsSummary({ games, periodStats, shots, reboundControls, puckPlaying });

    const systemPrompt =
      "You are a goaltending coach's assistant. You answer a goalie's or coach's questions " +
      "about THIS SEASON's performance using only the stats summary provided below. " +
      "Be specific and reference actual numbers from the summary. If the summary doesn't " +
      "contain enough information to answer confidently, say so plainly rather than guessing. " +
      "Keep answers focused and practical — this is for a goalie or their coach, not a general audience.\n\n" +
      "STATS SUMMARY:\n" + statsSummary;

    const anthropicRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": process.env.ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01"
      },
      body: JSON.stringify({
        model: CLAUDE_MODEL,
        max_tokens: 700,
        system: systemPrompt,
        messages: [
          { role: "user", content: question }
        ]
      })
    });

    if (!anthropicRes.ok) {
      const errText = await anthropicRes.text();
      throw new Error(`Anthropic API error ${anthropicRes.status}: ${errText}`);
    }

    const anthropicData = await anthropicRes.json();

    const answerText =
      (anthropicData.content || [])
        .filter(block => block.type === "text")
        .map(block => block.text)
        .join("\n") || "No response generated.";

    res.status(200).json({ answer: answerText });

  } catch (error) {

    console.error(error);
    res.status(500).json({ error: error.message || "Something went wrong." });

  }

}
