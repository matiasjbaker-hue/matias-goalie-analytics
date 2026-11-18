#!/usr/bin/env bash
# One-time setup: connect Review's "GoalieIQ model" button to Modal.
#
#   bash ml/video/setup_shot_api.sh
#
# 1. Makes a random key, saves it as the Modal secret `goalieiq-shot-api`
#    (SHOT_MODEL_SECRET) and copies it to the clipboard. It's never printed.
# 2. Deploys the Modal app, which prints the shot_api web address.
# Then add both to Vercel (Project -> Settings -> Environment Variables):
#    SHOT_MODEL_SECRET = the key on your clipboard
#    SHOT_MODEL_URL    = the https://...shot-api....modal.run address
# and redeploy the site. Re-running makes a new key: update Vercel to match.
set -euo pipefail
cd "$(dirname "$0")/../.."

tmp=$(mktemp)
chmod 600 "$tmp"
trap 'rm -f "$tmp"' EXIT
key=$(openssl rand -hex 32)
printf 'SHOT_MODEL_SECRET=%s\n' "$key" > "$tmp"
ml/.venv/bin/modal secret create goalieiq-shot-api --from-dotenv "$tmp" --force > /dev/null
printf %s "$key" | pbcopy
unset key
echo "Saved the Modal secret goalieiq-shot-api. Its value is on your clipboard:"
echo "paste it into Vercel as SHOT_MODEL_SECRET now (copying anything else replaces it)."
echo
read -r -p "Press Return once it's pasted in Vercel, to deploy the Modal app… " _
printf '' | pbcopy
COLUMNS=400 ml/.venv/bin/modal deploy ml/video/shots_modal.py | tee /dev/stderr | grep -o 'https://[^ ]*shot-api[^ ]*' | head -1 | sed 's/^/\nAdd this to Vercel as SHOT_MODEL_URL: /'
