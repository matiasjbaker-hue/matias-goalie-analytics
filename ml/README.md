# GoalieIQ ML — automatic shot detection

Goal: find every shot on the tracked goalie in full game film automatically,
so the admin confirms and tags proposed moments instead of scrubbing 1–3 hour
videos. (Later: predict each shot's tags too.)

Status (2026-11-10): round 3 (video model, tracked net mirrored to the left)
is the best so far, F1 0.36, but still **not usable for review**; see section 5.
The PC route in section 0 was replaced by Modal. Everything in `ml/data/` and
`ml/models/` is git-ignored (goalies' film and stats).

**Paused (2026-11-10) to collect more tagged games.** To pick it up again, follow
[section 6](#6-resuming-when-there-are-more-tagged-games). (Section 0, the PC setup, is superseded by Modal.)

## 0. Setting up the PC (start here)

The PC: Windows 11/10, AMD Radeon RX 6750 XT (12 GB). The work moved here from
a MacBook (M2, 8 GB) that can't train video models.

### Step 1: copy two files from the Mac

On the Mac, run in Terminal:

```bash
cp ~/matias-goalie-analytics/.env ~/Desktop/goalieiq.env
cp ~/matias-goalie-analytics/ml/data/csv-export.zip ~/Desktop/
```

- `csv-export.zip` (150 KB): the four Supabase tables the dataset is built
  from (games, shots, videos, Video Review drafts).
- `goalieiq.env`: the R2 keys for reading game film. **It contains secrets.**

Move both to the PC by USB stick or a *private* Google Drive / OneDrive folder.
Don't send `goalieiq.env` by email or chat, and never commit it. After it's on
the PC, delete the Desktop copy on the Mac and any uploaded copy.

(Alternative to copying the keys: make a separate read-only token for the PC,
see "R2 keys" below.)

### Step 2: install the tools on the PC

- **Claude desktop app** (Code tab), signed in
- **Git**: https://git-scm.com/download/win
- **Node.js 20 or newer** (LTS): https://nodejs.org
- **Python 3.12** (64-bit, tick "Add to PATH"): https://www.python.org/downloads/windows/
  (3.12 rather than the newest Python, because the AMD PyTorch builds lag behind)
- **AMD Adrenalin driver**, latest: https://www.amd.com/en/support

### Step 3: start a Claude Code session and paste this

Open a Claude Code session on a folder such as `C:\Users\<you>\code` and say:

> Clone https://github.com/matiasjbaker-hue/matias-goalie-analytics and check
> out branch `ml/dataset-export` and run `npm install`. Unzip my `csv-export.zip` (in Downloads) into
> `ml/data/csv/` and rebuild the dataset with
> `node ml/export-dataset.mjs --from-csv ml/data/csv`. Then read `ml/README.md`
> and start on round 2, beginning with the GPU check in section 3a.

Then move `goalieiq.env` into the project folder yourself and rename it to
exactly `.env`. In File Explorer, turn on View → Show → File name extensions so
Windows doesn't keep it as `.env.txt`. It's git-ignored.

### Step 4: what "working" looks like

1. `npm install` runs in the repo (it brings in ffmpeg and the R2 client).
2. The dataset rebuild prints **49 games, 1479 shots, 29 games usable for
   detection**.
3. The GPU check in section 3a prints `ok` (it actually trains a step, not just
   detects the card).
4. Only then cut clips and train (section 3b).

### R2 keys

`.env` needs these four lines, with no quotes and no spaces around `=`:

    R2_ACCOUNT_ID=dd84d45f3ed7e915a1bc634ef02f2e02
    R2_BUCKET_NAME=goalie-game-footage
    R2_ACCESS_KEY_ID=<from goalieiq.env, or a new token>
    R2_SECRET_ACCESS_KEY=<from goalieiq.env, or a new token>

The account ID and bucket name aren't secret. The two keys are. To make a
separate key for the PC, go to Cloudflare dashboard → R2 Object Storage →
Manage API tokens → **Create Account API token**, with Permissions **Object
Read only** on bucket `goalie-game-footage` only. The values show once.
Leave the existing token named "token" alone (read & write, the live site
probably uses it). A Supabase key isn't needed: the CSV route covers the data.

### Things to know

- The Mac-only parts (`ml/detect/featurize.swift`, Apple Vision) don't run on
  Windows and aren't needed for round 2. `train.py`'s evaluation functions
  (`pick_peaks`, `match`, `evaluate`) are plain numpy and should be reused.
- Film is streamed from R2 with ffmpeg range requests, so full games are never
  downloaded. Clips for training are small; keep them under `ml/data/`.
- The Mac ran low on disk and memory. The PC shouldn't, but
  `extract-features.mjs` has the pause-on-low-disk logic to copy if needed.
- One game is dated 2026-12-11 (probably a typo for 2025). Shot type is 83%
  "Snap", likely the tagging default, so don't train a shot-type head on it yet.

## 1. Data

Source of truth is Supabase + R2 (bucket `goalie-game-footage`).

| What | Count |
|---|---|
| Games with tagged shots | 49 (18 goalies) |
| Tagged shots | 1,479 (134 goals), all tagged by a human |
| Shots with any video | 1,331 |
| **Games with full film + exact shot times** | **29 games / 32 files, 920 shots, ~36 h of live play** |

How shot times are found: Video Review drafts (`video_shot_drafts.t_seconds`)
are the approved shot moments in the full film. Published `Shots` rows are
written in draft time order, so pairing by order matches every tag field
exactly (26 games); the rest are aligned on outcome/type/location/strength.
`period_marks._cuts` are removed stretches (warm-up, intermissions);
`period_marks._net` is the tracked net side in period 1 (swaps in period 2).
Some films have parts (`parent_video_id`).

### Rebuild the dataset

Either with a Supabase service key in `.env`:

    node --env-file=.env ml/export-dataset.mjs

or without one: run the four queries in `ml/export-queries.sql` in the Supabase
SQL editor, "Download CSV" each into `ml/data/csv/` as `Games.csv`,
`Shots.csv`, `game_videos.csv`, `video_shot_drafts.csv`, then:

    node ml/export-dataset.mjs --from-csv ml/data/csv

Output: `ml/data/shots.jsonl` (one labelled shot per line, with `film`
{video, t_seconds} and/or `clip`), `ml/data/games.jsonl` (per film:
`shot_times`, `goal_times`, `period_marks`, `duration_seconds`),
`ml/data/summary.md`.

Reading video needs a **read-only R2 token** in `.env`:

    R2_ACCOUNT_ID=dd84d45f3ed7e915a1bc634ef02f2e02
    R2_BUCKET_NAME=goalie-game-footage
    R2_ACCESS_KEY_ID=...
    R2_SECRET_ACCESS_KEY=...

`--clips` on the export cuts one MP4 per shot straight from R2 (no full
downloads): film shots as t-4 s..t+3 s, 640 px, no audio.

## 2. Round 1: frame features + gradient boosting (Mac) — failed

`ml/detect/` (macOS only for the featurizer):

- `extract-features.mjs` streams each film from R2 through ffmpeg (4 fps,
  320x180) into `featurize.swift` (Apple Vision feature print every 0.5 s +
  8x4 motion grid). Tagged span only, cuts removed. ~548 MB for 36 h.
- `train.py` (numpy + scikit-learn) — 673 features per half-second,
  HistGradientBoosting, peaks at least 2.5 s apart, matched to tagged shots
  within ±2 s. **5-fold cross-validation with whole goalies held out.**
  Writes `ml/data/eval/report.md` + per-film found/missed/extra CSVs.
- `predict.py` — shot moments for one film as `[{t, score}]`.

Result (920 shots, 13 goalies held out in turn):

| Setting | Recall | Precision | Extra moments / game hour |
|---|---|---|---|
| Review (max recall) | 62% | 4.5% | ~330 |
| Best F1 (0.13) | 18% | 9.9% | ~42 |

A random proposal every ~10 s already gets ~40% recall, so this is barely
above chance. Diagnosis: labels are fine (whole-frame motion peaks 2–3 s
*before* tagged shots, as expected for a rush ending in a shot), but the
signal is tiny (+0.24 SD). At 320x180 the puck is invisible and generic
whole-frame features can't tell "shot" from "players near the net".
**Keep the evaluation, dataset and report format; replace the model.**

## 3. Round 2 (next): fine-tune a video model on the GPU PC

PC: Windows, AMD Radeon RX 6750 XT (12 GB, gfx1031, RDNA2).

### 3a. Get PyTorch on the GPU (do this first, verify before anything else)

RDNA2 is not on AMD's official Windows PyTorch list. Try in this order and
stop at the first that passes the check below:

1. **Native Windows, ROCm "TheRock" nightly wheels**: they list gfx1031 as a
   target (`device-gfx1031` extra). See
   https://github.com/ROCm/TheRock/blob/main/RELEASES.md. Community reports
   of `torch.cuda.is_available() == True` on a 6750 XT with ROCm 7.15;
   `torch.compile` reportedly doesn't work on RDNA2 Windows: don't use it.
2. **Linux (Ubuntu) dual-boot + ROCm**, with `HSA_OVERRIDE_GFX_VERSION=10.3.0`
   (the most proven route for 6700/6750 XT).
3. torch-directml: stale (PyTorch ≤2.4, last release 2024). Last resort.
4. If none work: rent a cloud GPU (Modal / RunPod). Same code.

Check (must train, not just detect the card):

```python
import torch, torchvision
print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0))
m = torchvision.models.video.r2plus1d_18(weights="DEFAULT").cuda()
x = torch.randn(4, 3, 16, 112, 112, device="cuda")
loss = m(x).float().mean(); loss.backward(); print("ok", loss.item())
```

### 3b. Plan

1. **Clips** (platform-independent, extend `export-dataset.mjs` / a new
   `ml/video/make-clips.mjs`): from the 32 films, cut short windows straight
   from R2 with ffmpeg (keep resolution higher than round 1: e.g. 16 frames
   over ~2 s at 224 px short side):
   - positives: centred on each of the 920 shot times (jitter ±0.5 s);
   - hard negatives: 3–8 s away from shots (same play, no shot);
   - easy negatives: random live-play windows ≥10 s from any shot;
   - ~1:4 positive:negative. Skip `_cuts`. Keep goalie/user_id per clip.
2. **Model**: pretrained video backbone fine-tuned as shot / no shot.
   Prefer pure-PyTorch torchvision models (no custom CUDA kernels → safest on
   ROCm): `r2plus1d_18` or `mvit_v2_s`; mixed precision; batch to fit 12 GB.
   Optional second head: which side of the frame the action is (tracked net).
3. **Spotting**: slide over the live play of a held-out film at 0.5 s stride,
   then reuse `pick_peaks` / `match` / `evaluate` from `ml/detect/train.py`
   (same ±2 s matching, same goalie-held-out folds, same `report.md` table),
   so round 1 and round 2 numbers compare directly.
4. **Target to be useful**: ≥95% recall at ≤60 extra moments per game hour
   (≈1 per minute; the admin skims those). Compare against the existing
   Claude-still "detect" and Twelve Labs paths in the review screen.

### Data on the PC

See [section 0](#0-setting-up-the-pc-start-here). `ml/data/` isn't in git:
unzip `csv-export.zip` into `ml/data/csv/` and run the CSV rebuild, or
re-export from the Supabase SQL editor (section 1).

## 4. Round 2 results: video model on Modal (2026-11-10)

`ml/video/shots_modal.py` (Modal app `goalieiq-shots`, volume `goalieiq-ml`,
secret `goalieiq-r2`) + `ml/video/launch.py`. 4 s windows at 8 fps / 228x128:
920 shots + 4,749 no-shot windows; r2plus1d_18 (Kinetics) fine-tuned 8 epochs
on 2 s clips; whole goalies held out (5 folds); every 0.5 s of held-out film
scored. Report: `ml/data/eval_video/report.md`.

    ml/.venv/bin/modal deploy ml/video/shots_modal.py
    ml/.venv/bin/python ml/video/launch.py            # start GPU jobs (survive disconnects)
    ml/.venv/bin/python ml/video/launch.py --status
    ml/.venv/bin/python ml/video/launch.py --report

| | Round 1 (frames) | Round 2 (video) |
|---|---|---|
| Best F1 | 0.13 | **0.29** |
| Found at ~60 extra/game hour | ~15% | **51%** |
| Most found (any setting) | 62% at 330 extra/h | 89% at 416 extra/h |
| Timing (median) | 0.85 s | 0.67 s |

Data-amount test (same held-out goalies): 6 → 13 → 26 training films gave
best F1 0.16 → 0.22 → 0.29 and found-at-60/h 29% → 37% → 51%. Still climbing
steadily (~+0.065 F1 per doubling), so more tagged games help, but data alone
would need many hundreds of games to reach the review target.

False alarms at the 60/h setting: 42% are more than 60 s from any tagged shot
(likely shots/scrambles at the *other* net: the model can't tell which goalie
is tracked), 13% are 2–10 s from a tagged shot. Films with the net side marked
(7) did no better, so the side hint alone isn't enough with this little data.

Cost: about $24 of Modal credit in total (image build, clip prep, one run lost
to a dropped connection, and the 15 GPU jobs at ~1 h each on A10G). Re-running
the 15-job set costs roughly $15–17.

Next levers, most promising first: (1) teach "which net": mark the net side
for all films and/or predict shot-at-left/right separately; (2) higher
resolution or crops around the nets, longer clips (3–4 s), a larger backbone;
(3) more tagged games over time (Video Review keeps adding them).

## 5. Round 3: tell the model which net (2026-11-10)

Net side labelled for all 32 films from frames at tagged shots
(`ml/video/net_frames.py` -> `ml/video/net_sides.json`; agrees with the 7
films already marked in Video Review; 3 goal-cam films never flipped; 1366,
1226 and the U11 game 1743-45 are low confidence). Every clip is mirrored so
the tracked net is on the left, so the model only answers "shot on the left
net?" and shots at the other end become plain negatives. At inference the
admin's Video Review net side tells it how to mirror.

    ml/.venv/bin/python ml/video/launch.py --net [--only 1,2,3] [--status|--report]

Report: `ml/data/eval_video_net/report.md`. Same 5 goalie-held-out folds:

| | Round 2 | Round 3 |
|---|---|---|
| Best F1 | 0.29 | **0.36** |
| Found at ≤120 extra/h | 67% | **70%** |
| Found at ≤60 extra/h | 51% | **59%** |
| Found at ≤30 extra/h | 37% | **45%** |
| Most found (extra/h) | 89% (416) | 83% (259) |

Real gain everywhere a reviewer would operate, still far from the target
(≥95% found at ≤60 extra/h). Cost: ~$3.95 for 5 folds after cutting GPU jobs
to 4 CPU / 16 GB (~$0.80 per fold) — CPU and memory had been ~60% on top of
the GPU. Note: raising a Modal spend limit restarts jobs that the limit had
stopped; cancel stale calls (`modal.FunctionCall.from_id(id).cancel()`).

## 6. Resuming when there are more tagged games

Paused on 2026-11-10 at 32 films with full film + shot times (29 games).
The data-amount test showed accuracy still rising with more games, so the
plan is to retrain at **~60+ film games**. Until then nothing here costs
anything: Modal bills only while jobs run, and the 17.7 GB of saved clips on
the `goalieiq-ml` volume is inside Modal's free 1 TiB of volume storage.

### While collecting (no code needed)

- Tag new games through **Video Review** (not Live Tag): only Video Review
  saves each shot's time in the full film, which is what the model learns from.
- **Set the net side** for period 1 in Video Review on every game (and per
  period if the ends don't switch the usual way). Round 3 depends on it, and
  it saves re-labelling frames by hand.
- Prefer variety: new rinks, cameras and age levels help more than more games
  from the same rink.

### Retraining (about 1 hour of work, ~$1 per fold on Modal)

1. Re-export the data: Supabase SQL editor -> the 4 queries in
   `ml/export-queries.sql` -> Download CSV into `ml/data/csv/` -> 
   `node ml/export-dataset.mjs --from-csv ml/data/csv`. Check `summary.md` for
   the new count of "games usable for shot detection".
2. Net sides: films marked in Video Review are picked up automatically
   (`period_marks._net` / `._sides`). For any that aren't, run
   `ml/.venv/bin/python ml/video/net_frames.py` and add them to
   `ml/video/net_sides.json`.
3. Cut clips for the new films only (already-prepared films are skipped):
   `ml/.venv/bin/modal run ml/video/shots_modal.py --step prepare`
4. `ml/.venv/bin/modal deploy ml/video/shots_modal.py`, then train in two waves
   so a budget stop can't lose everything:
   `ml/.venv/bin/python ml/video/launch.py --net --only 1,2,3`, check spend on
   modal.com -> Usage & billing, then `--only 4,5`, then `--report`.
   Old results are skipped by label: to retrain on the bigger dataset, first
   remove the old `net100%_fold*.json` files from the volume's `scores/`
   folder (`ml/.venv/bin/modal volume rm goalieiq-ml scores/net100%_fold1.json`
   etc.), or the launcher will think those folds are done.
5. Compare `ml/data/eval_video_net/report.md` with the round 3 numbers in
   section 5 (F1 0.36; 59% found at ≤60 extra/h).

Budget notes: the Starter plan includes $30/month (resets on the 1st). Keep a
spend limit set. If a limit stops jobs, raising it **restarts** them: list
containers (`modal container list`) and cancel stale calls before launching new.

### Next model ideas, for when data alone plateaus

Higher resolution or crops around the nets (the puck is invisible at
228x128), longer clips (3–4 s), a larger backbone (`mvit_v2_s`), and
comparing against the existing Claude-still / Twelve Labs detection.
