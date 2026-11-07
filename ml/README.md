# GoalieIQ ML — automatic shot detection

Goal: find every shot on the tracked goalie in full game film automatically,
so the admin confirms and tags proposed moments instead of scrubbing 1–3 hour
videos. (Later: predict each shot's tags too.)

Status (2026-11-07): dataset built, first model tried and **not good enough**,
next step is a video model trained on a GPU PC. Everything in `ml/data/` and
`ml/models/` is git-ignored (goalies' film and stats).

**Starting on the PC?** Follow [section 0](#0-setting-up-the-pc-start-here) first.

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
