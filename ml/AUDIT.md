# Shot detection: audit and plan (2026-11-22)

Why the GoalieIQ shot model flags ~100 moments per game hour instead of
"only the shots", what the research says works, and what we're doing next.
Aggregate numbers only; no goalie or team details.

## 1. Where we are

| Round | What changed | Result (whole goalies held out) |
|---|---|---|
| 1 | Frame features + gradient boosting (4 fps, 320x180) | best F1 0.13; 62% found at ~330 extras/h |
| 2 | Video model: R(2+1)D-18 (Kinetics), 2 s clips, 8 fps, 228x128 | F1 0.29; 51% found at ≤60 extras/h |
| 3 | Mirror so the tracked net is always on the left | F1 0.36; 59% at ≤60/h |
| 4 (live) | Same recipe, 98 films / 72.6 h / 1,793 shots / 25 goalies | F1 0.40; 70% at ≤60/h; 80% at ~100/h; 87% at ~220/h |
| 5 | Sharper net-side crop + round 4's mistakes as negatives | **worse** (150 vs 109 extras/h at 80% found, same 60 films) |

Side tests:

- **Frame review:** the confident extras are real attacks and scrambles at the
  tracked net (wide, blocked, goalie-down plays). In one game the broadcast
  shot counter confirmed the tags are complete. The extras are not missed tags.
- **Blind still test:** full-resolution close-ups of the net, 16 real shots vs
  16 near-misses, judged by eye: AUC 0.61, barely better than a coin flip.
- **Audio (AudioSet AST embeddings):** sound alone AUC 0.70. Blended with the
  video score it gives 10–25% fewer extras. Helpful, not decisive.
- **More data:** 6 → 13 → 26 → 78 training films gave F1 0.16 → 0.22 → 0.29 →
  0.36–0.42. Each doubling helps less than the last, and 400 games projects to
  about F1 0.45.

## 2. Why it isn't working

Ranked by likely impact. Items 1–3 are design problems; they would hold back
any amount of data.

1. **Wrong model shape for this task.** We classify isolated 2-second clips
   and slide that classifier over the game every 0.5 s. The precise-event
   spotting literature measures this exact design against the alternative.
   On figure skating, a clip classifier with the same backbone scored 61.8 mAP
   vs 81.0 for a dense model that labels every frame and uses a temporal model
   over long clips. Removing the temporal model alone cost 6.7 mAP, and
   removing both the temporal modules cost 36 (E2E-Spot, ECCV 2022). The
   authors say clip sampling "fails to overcome the large foreground/background
   imbalance" and that precise spotting "requires dense sampling".
2. **The negatives we train on aren't the ones that fool it.** Each shot gets
   ~4 random "no shot" clips, about 100 per hour of film. At scan time the
   model judges ~7,200 moments per hour, and the hard ones (attacks without a
   shot on goal) are almost never in training. So it learned "attack at the
   net" rather than "shot on goal". Dense training labels every frame of every
   sampled clip, so every near-miss in a clip becomes a negative example.
3. **It can't see what decides the call.**
   - **Resolution:** at 228x128 the puck is about a third of a pixel, and the
     goalie is ~15 px tall.
   - **Frame rate:** 8 fps catches only 3–5 frames of a shot.
   - **Context:** the clip ends 0.75 s after the moment, before the rebound,
     freeze, whistle or faceoff that a human tagger uses.
   - **What winners use:** the 2023 SoccerNet ball-action winner used 1280x736
     frames at 12.5 fps for a similarly tiny ball. E2E-Spot lost 5–8 mAP going
     from 224 px to 112 px, even for big-object sports.
4. **Backbone.** A Kinetics 3D CNN at low resolution, re-run on each frame ~4
   times because the windows overlap. The current best practice is an ImageNet
   2D CNN with temporal shifts plus a GRU or encoder-decoder (E2E-Spot,
   T-DEED, which won SoccerNet 2024). It processes each frame once, so it's
   also cheaper per hour of film.
5. **The labels only cover shots on goal.** Wide and blocked attempts are
   unlabelled. At our resolution they look identical, so the model needs the
   aftermath and puck evidence above to separate them. Review's S/D clicks on
   model moments aren't fed back yet, though they are free, human-verified
   near-miss labels.
6. **Round 5 changed three things at once** (crop, resolution, mined
   negatives), so we can't say which one hurt.

What's fine: the dataset and alignment (tags line up with the film), the
whole-goalie cross-validation, the matching tolerance and the report format.
Keep them.

## 3. What others found

- **E2E-Spot** (Hong et al., ECCV 2022):
  - Model: RegNet-Y-200MF with gate/temporal shift modules, then a 1-layer
    bidirectional GRU, with a label for every frame.
  - Training: 100-frame clips at 224 px, foreground weighted 5x, one GPU,
    about 7 GPU-hours.
  - Clip length mattered: 8 frames 73.7 → 100 frames 81.0.
  - https://arxiv.org/abs/2207.10213
- **T-DEED** (Xarles et al., 2024; won SoccerNet Ball Action Spotting 2024):
  the same backbone with an encoder-decoder temporal model; +4 mAP over
  E2E-Spot. https://arxiv.org/abs/2404.05392
- **SoccerNet Ball Action Spotting 2023, 1st place** (tiny ball, broadcast):
  - Input: grayscale 1280x736 at 12.5 fps.
  - Model: an EfficientNetV2-B0 2D encoder over stacked frames, then 3D blocks.
    This "slow fusion" took mAP from 65% to 80%.
  - Training: hard-negative sampling from out-of-fold predictions, focal loss,
    Gaussian-smoothed peak picking.
  - https://github.com/lRomul/ball-action-spotting
- **Hockey specifically** (Vats et al., Waterloo, 2021): 9k NHL broadcast clips,
  R(2+1)D at 256 px. A 4-class clip task reached only F1 ~0.58–0.60 on "Shot",
  and puck location didn't help that class. Clip classification of shots is
  hard even on pro footage. https://arxiv.org/abs/2105.10563
- **Commercial "automatic" hockey data** (Spiideo AutoData) uses dedicated
  cameras, including one behind each net, plus professional breakdown. No
  amateur tool we found reliably auto-tags shots on goal.
  https://www.spiideo.com/news/autodata-for-ice-hockey-the-ultimate-power-play/
- **Net and goalie detection:** HockeyAI has ~2,000 1080p frames with boxes for
  goal, goaltender, puck and players (MIT licence, broadcast).
  https://huggingface.co/datasets/SimulaMet-HOST/HockeyAI

## 4. Plan

**Step 1, now: round 6, a dense spotting model (E2E-Spot recipe).**

- **Input:** 448x252 at 12.5 fps, ~2x round 4's resolution and 1.5x its frame
  rate, still mirrored so the tracked net is on the left.
- **Clips:** 8 seconds (100 frames), so the model sees build-up, shot and
  aftermath.
- **Model:** ImageNet RegNet-Y-200MF with temporal shifts in every block, a
  bidirectional GRU, and a shot/no-shot prediction for every frame (±0.24 s
  around each tag).
- **Training clips:** 40% around tagged shots, 30% around round 4's
  out-of-fold false alarms, 30% random. Labels always come from the tags, so
  sampling can't add label noise.
- **Comparison:** same goalie folds as round 4, compared on the same 60 films
  (folds 1–3) with the same extras/hour metric.
- **Cost:** about $3–5 to cut 12.5 fps copies, plus ~$2–3 per fold.
- **Stop rule:** keep it only if it cuts extras by ≥30% at 70–80% found.

**Result of step 1 (2026-11-22): round 6 failed.** Compared on the same 60
games (folds 1–3), extras per hour:

| Model | Best F1 | at 80% found | at 70% | at 60% |
|---|---|---|---|---|
| Round 4 | 0.42 | 109 | 57 | 35 |
| Round 6 | 0.26 | 492 | 190 | 124 |
| Round 4 + 15% round 6 | 0.43 | 106 | 56 | 36 |

- **Not a timing bug:** averaged around every tagged shot, both models' scores
  peak exactly at the tag. Round 6's peak is just weak: 0.12 vs round 4's 0.58.
- **It memorized:** training loss fell from 0.33 at epoch 7 to 0.09 at epoch 15.
  A model that learned nothing would sit at about 0.44. Held-out games stayed
  poor.
- **Why:** with ~1,400 tagged shots per training fold, a higher-resolution
  per-frame model memorizes clips, rinks and goalies. Round 4's small
  Kinetics-pretrained model, trained briefly at low resolution, generalizes
  better.
- **Lesson:** on this much data, extra capacity and resolution need strong
  regularization, or must be confined to a narrow sub-task. Round 4 stays live.
- **Cost:** ~$9.

**Step 2, now: a full-resolution checker on round 4's flagged moments.**

- Re-judge each flagged moment from a full-resolution crop around the net
  (located with a detector trained on HockeyAI's goal/goaltender boxes), at
  25 fps, 2 s before to 4 s after, with sound.
- Train it on the ~17,500 flagged moments we already have labels for.
- This is the only route where the puck itself is visible (2–3 px at 1080p).

*Feasibility check for step 2 (2026-11-22):* I ran OWLv2
(`google/owlv2-base-patch16-ensemble`, zero-shot, prompts "a hockey goal
net" / "an ice hockey goaltender") on full-resolution frames at 28 flagged
moments from 14 games (720p–1080p, two 640x360, goal cams included).

- **Hit rate:** about 20 of 28 gave a good crop of the tracked net with the
  goalie and the players in front, far more detail than any input so far.
- **Fixable misses:**
  - goal-cam films need no "tracked side" filter;
  - the crop should scale with the net's box, not a fixed size (fisheye goal
    cams);
  - frames with no net in view (scoreboard overlay, ice resurfacing, camera on
    the ads) need a score floor, box-shape checks and the net position from
    neighbouring frames.
- **Speed:** ~0.5 s per frame unbatched. Batch it, or train a small fast
  detector on OWLv2's boxes, before running it on every candidate.

*Step 2 first results (2026-11-23, `ml/video/stage2_modal.py`):* all 17,528
round-4 moments on 98 games.

- **Method:** full-resolution close-ups of the net (t−2 to t+4 s, 160×160),
  described by a frozen Kinetics R(2+1)D. Each signal becomes an out-of-fold
  score, then the scores are stacked (two levels; one classifier on all the
  raw features memorizes).
- **Close-ups alone:** AUC 0.79 overall, 0.70 on round 4's confident moments,
  the same as round 4 there.

| Extras/h | at 80% found | at 70% | at 60% |
|---|---|---|---|
| Round 4 only (98 games) | 110 | 61 | 39 |
| Round 4 + close-up (stacked) | 93 (−15%) | 53 (−13%) | 33 (−15%) |
| Round 4 only (30 games with sound) | 65 | 44 | 27 |
| Round 4 + close-up + sound (stacked) | 46 (−29%) | 30 (−32%) | 21 (−22%) |

With sound finished for every game (88 of 98 have an audio track),
extras/h:

| 88 games with sound | AUC (confident) | at 80% found | at 70% | at 60% | at 50% |
|---|---|---|---|---|---|
| Round 4 only | 0.69 | 120 | 66 | 43 | 27 |
| + sound | 0.77 | 103 | 48 | 31 | 19 |
| + close-up + sound | 0.80 | 87 (−28%) | 43 (−35%) | 25 (−42%) | 15 (−44%) |

**This clears the 30% bar at 70% and below, and nearly at 80%.** The first
real step forward since round 4. Each signal sees something the others
don't: round 4 the play, the close-up the goalie and crease, the sound the
whistle and crowd.

**Fine-tuned close-up model (2026-11-23):**

- **Recipe:** Kinetics R(2+1)D trained on the close-ups, 5 goalie folds,
  round 4's recipe (8 epochs, backbone lr 1e-4, dropout 0.5, random 144 crops
  and ±2-frame jitter). 32 frames from t−1 to t+2.8 s.
- **It generalizes:** on held-out goalies, AUC 0.88, and 0.82 on round 4's
  confident moments. That's better than round 4 alone (0.84 / 0.70).
- **Why it didn't memorize like round 6:** it trains on candidate moments, so
  the negatives are near-misses from the same rinks. The input is a crop of
  the net, so there's little scenery to memorize. And it starts from a
  Kinetics video model and trains briefly.

Final stack on all 98 games (sound used where the game has it), extras/h:

| | AUC (confident) | at 80% found | at 70% | at 60% | at 50% |
|---|---|---|---|---|---|
| Round 4 only | 0.70 | 110 | 61 | 39 | 26 |
| Close-up model alone | 0.82 | 97 | 36 | 21 | 14 |
| **Round 4 + close-ups + sound** | **0.84** | **64 (−42%)** | **29 (−52%)** | **16 (−59%)** | **10 (−62%)** |

How sure it can be (share of all tagged shots found at a given precision):

| Precision | Round 4 | Round 4 + close-ups + sound |
|---|---|---|
| 50% | 9% | 58% |
| 60% | 2% | 38% |
| 70% | 1% | 22% |

There's no ≥90%-precision tier yet, so nothing can be auto-accepted without
a person. The list to check is about twice as clean, though: at 60–70%
found, roughly 1 in 2 to 1 in 3 flagged moments is a real shot, against
1 in 4 to 1 in 5 today.

**In Review (2026-11-23):**

- **How it runs:** "Find shots" asks the shot service for a second opinion
  (`stage2: true`). Round 4 finds the moments. `goalieiq-stage2`'s
  `rescore()` cuts close-ups from the original and adds the game's sound,
  using the final models trained on all 98 games, then stacks them into
  `s2`.
- **Site change:** PR #8. Merging it is the switch; the cloud side is
  deployed and inert without the flag.
- **Live tests:** on 4 real games (camera behind the net, no sound, two side
  cameras), live matched evaluated on 86–96% of keep/drop decisions, at about
  2.6 min and $0.08 per game. Run through the site's own entry point
  (`suggest_shots`) on one game: 3.9 min total, no errors.
- **Still to check:** a run from the deployed site with an admin login after
  merging, and a test on games tagged after the 2026-11-17 export (the only
  truly unseen ones).
- **Still too many extras for automation** (29/h at 70% found, 64/h at 80%).
  Next levers: sharper close-ups (256 px, 25 fps), more labels
  (W / Shift+W, new games), a camera behind the net.

**Process changes (free):**

- Feed Review's S/D decisions back as labels. Re-export after a few weeks of
  Review use.
- Keep tagging through Video Review with net sides set.
- Tag wide and blocked attempts too. Review now has this: W marks a missed
  shot and Shift+W a blocked one, saved as `period_marks._attempts`.
  Round 6+ training uses them as confirmed near-misses.
- Change one thing per round.

**Hardware option:** a camera behind or above the net (what Spiideo's pro
setup does) makes the shot-on-goal call easy for both people and models.
