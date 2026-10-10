# Local puck/player tracking

A standalone, local, open-source computer-vision pipeline that tracks
players and the puck in game video and derives shot events from the
puck's trajectory using real math -- not an AI model guessing at labels.
It's independent of the rest of this repo (no Supabase/Stripe/Vercel
calls); it just reads a video file and writes a JSON report (and
optionally an annotated video).

It exists as a from-scratch, no-recurring-cost alternative/complement to
the Twelve Labs integration in `api/_lib/admin-twelvelabs.js`, which asks
a video-language model to describe shots. This tool instead tracks the
puck's actual pixel/rink position frame by frame and detects a shot as a
measured acceleration event aimed at the net -- it doesn't get more
accurate by taking your word for it, so verify it against real footage
before trusting its output (see "Accuracy expectations" below).

## How it works

1. **Players** -- Ultralytics YOLO (`yolov8n.pt` by default, auto-downloaded
   on first run) detects people; its built-in ByteTrack tracker gives each
   skater a persistent ID across frames.
2. **Puck** -- there's no reliable pretrained "hockey puck" class in any
   open YOLO model, so detection is classical CV first: background
   subtraction finds anything moving, candidates are filtered by size,
   elongation (motion blur smears a round puck into a streak) and
   darkness (a puck reads near-black against bright ice -- the strongest
   cheap signal available). You can optionally plug in a custom-trained
   YOLO puck model (`--puck-weights`) and its detections are fused in as
   higher-trust candidates.
3. **Fusion & tracking** -- all puck candidates feed one Kalman filter
   (constant-velocity model, `kalman.py`) with Mahalanobis-gated
   association (`config.PUCK_GATE_CHI2`). The filter's own velocity
   estimate is used downstream (not finite-differenced raw positions),
   and it coasts (predicts with no correction) through brief detection
   gaps -- motion blur, a player screening the puck -- for up to
   `PUCK_MAX_COAST_FRAMES`.
4. **Rink calibration** -- a one-time manual step (`rink_calibrate.py`):
   click six known rink markings (goal posts, defensive faceoff dots,
   blue line x boards) on a representative frame. `cv2.findHomography`
   turns those into a pixel->rink-feet mapping, using the same rink
   markings GoalieIQ's own shot map already draws (see `DESIGN.md`).
   This is what lets puck speed come out in real mph and shot direction
   be judged against the actual net location, instead of meaningless
   pixel units.
5. **Shot detection** (`shot_detector.py`) -- a shot is a local peak in
   puck speed that (a) clears `SHOT_RELEASE_SPEED_FTPS`, (b) was clearly
   slower just before (a real acceleration, not a cruising pass/clear
   that happens to be fast), and (c) points at the net's mouth within
   `SHOT_DIRECTION_TOLERANCE_DEG`. The shooter is whichever tracked
   player was within stick range of the puck just before release.

This is scoped to **one net at a time** -- the tracked goalie's net,
matching how GoalieIQ already works (shots are tracked against one
goalie, not full-ice play at both ends). If the camera moves to the
other end mid-game (e.g. a period change), calibrate a new time segment
for that end; see `rink_calibrate.py --help`.

## Setup

Requires Python 3.9+. Your machine has an AMD GPU (not NVIDIA), so this
defaults to CPU inference, which is the reliable path on Windows. CPU
inference on a 1-3 hour game will be slow (plan for it to take longer
than the video's runtime) -- use `--stride`, `--start`/`--end`, or run it
on pre-trimmed clips instead of a full game while you're tuning
thresholds.

```bash
cd tracking
python -m venv .venv
.venv\Scripts\activate          # Windows
pip install -r requirements.txt  # pulls in torch via ultralytics; can take a while
```

Optional, faster-than-pure-CPU path on your AMD GPU: install
[`torch-directml`](https://pypi.org/project/torch-directml/) and pass
`--device dml` -- this is less battle-tested with Ultralytics than
CUDA, so fall back to `--device cpu` if it misbehaves.

## Usage

**1. Calibrate the rink once per camera position** (skip this for a
quick look without real-world shot detection):

```bash
python rink_calibrate.py --video game.mp4 --t 12.0 --out game_calibration.json
```

Opens a window on the frame at `t=12.0s`. Click, in order: near goal
post, far goal post, near faceoff dot, far faceoff dot, blue line at the
near board, blue line at the far board. Press `s` to skip a marking
that's off-screen (need at least 4 total), `u` to undo, `q` to save.

If the camera repositions partway through (e.g. the goalie switches
ends at a period break), add another segment:

```bash
python rink_calibrate.py --video game.mp4 --t 2450 --start 2430 --out game_calibration.json --append
```

**2. Run tracking + shot detection:**

```bash
python main.py --video game.mp4 --calibration game_calibration.json \
    --out game_results.json --annotate game_annotated.mp4
```

Watch `game_annotated.mp4`: player boxes with persistent IDs, the puck's
recent trail (red = actively tracked, orange = coasting through a gap),
and `game_results.json` has every detected shot:

```json
{
  "t_s": 812.43,
  "puck_rink_ft": [34.2, -6.1],
  "speed_mph": 58.3,
  "direction_deg_to_net": 11.2,
  "shooter_track_id": 7,
  "confidence": 0.81,
  "note": ""
}
```

## Tuning

Everything that controls detection sensitivity lives in `config.py`,
commented inline. Worth tuning first for your footage/level of play:

- `SHOT_RELEASE_SPEED_FTPS` / `SHOT_PRE_RELEASE_SPEED_FTPS` -- lower these
  for youth/slower shots; raise if you're getting false positives on hard
  passes.
- `PUCK_MAX_MEAN_GRAY`, `PUCK_MIN_AREA_FRAC`/`PUCK_MAX_AREA_FRAC` -- if the
  puck isn't being picked up at all, run with `--annotate` and look at
  whether candidates are being found but rejected (too bright/too
  big/too small for your camera's distance and lighting).
- `SHOT_DIRECTION_TOLERANCE_DEG` -- widen if real shots from sharp angles
  are being missed; narrow if clearing attempts that happen to point
  roughly net-ward are triggering false shots.

## Improving puck accuracy with a custom-trained model

The classical motion+darkness detector is a solid baseline on a fixed
camera over clean ice, but it will miss the puck in a scrum, against
glare, or when it's airborne (no ice-level motion to subtract against).
The highest-accuracy path is a small custom-trained YOLO model:

1. Pull ~500-1000 frames from your own footage (`cv2.VideoCapture` +
   `cv2.imwrite`, or extract every Nth frame with ffmpeg).
2. Label just the puck's bounding box in each (e.g. with
   [Roboflow](https://roboflow.com) or [CVAT](https://cvat.ai), both free
   for small datasets) as a single class.
3. Fine-tune: `yolo train model=yolov8n.pt data=puck.yaml epochs=100
   imgsz=960` (a puck needs a higher `imgsz` than the YOLO default to
   survive downscaling before it's a handful of pixels).
4. `python main.py ... --puck-weights runs/detect/train/weights/best.pt`

## Accuracy expectations

This pipeline is a tool for finding candidate shots fast, not a final
verdict -- same principle as the rest of GoalieIQ ("automation proposes,
a human can always correct", `PRODUCT.md`). Validate it against a known
clip (one you've already hand-tagged) before trusting it on new footage,
and expect to tune `config.py` for your specific camera angle, distance,
and rink lighting. Known limitations:

- Assumes a mostly-static camera (tripod/fixed mount). A panning or
  zooming camera breaks both the background-subtraction puck detector
  and the homography; recalibrate per segment if the camera moves, and
  expect lower accuracy on handheld footage.
- The puck is invisible to the motion detector while airborne over
  non-ice background (benches, glass, crowd) -- the Kalman filter will
  coast through this, but a long airborne shot can exceed
  `PUCK_MAX_COAST_FRAMES` and the track will reset.
- Shot attribution (which player shot it) depends on that player having
  a clean YOLO detection in the frames just before release; a tightly
  bunched scrum can leave `shooter_track_id: null`.

## Verifying the math without real footage

`python smoke_test.py` runs the Kalman filter, homography round-trip,
and shot-detection logic against a synthetic puck trajectory (a slow
drift, then a sharp release at the net, with a simulated detection
dropout) and checks the tracker survives the dropout and the shot
detector fires once, on the release, with the right shooter and a
plausible speed/angle. It does not and cannot validate real-world
detection accuracy -- that requires your own footage, which is why
`--annotate` exists: always eyeball a clip before trusting the numbers.
