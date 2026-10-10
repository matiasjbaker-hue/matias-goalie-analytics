"""
Puck detection and tracking.

There is no reliable pretrained open-source YOLO class for "hockey puck"
(COCO has no such class; "sports ball" occasionally fires on it but is
built for round balls, not a small black disc that's usually smeared by
motion blur). So detection is classical-CV first:

  1. Background subtraction (MOG2) finds anything moving.
  2. Candidate blobs are filtered by size, elongation and darkness
     (a puck reads near-black against bright ice -- the single strongest,
     cheapest cue available).
  3. If a custom-trained puck YOLO model is supplied (--puck-weights),
     its detections are added as a second, higher-trust candidate source.

All candidates feed a single Kalman filter (kalman.py) per
config.PUCK_GATE_CHI2 Mahalanobis gating: the nearest candidate inside
the gate updates the filter; if none qualifies, the filter coasts
(predicts with no correction) for up to PUCK_MAX_COAST_FRAMES, which is
exactly what's needed through motion blur or a brief screen by a player.
"""

import cv2
import numpy as np

import config
from kalman import ConstantVelocityKalman2D


class Candidate:
    __slots__ = ("x", "y", "source", "conf")

    def __init__(self, x, y, source, conf):
        self.x, self.y, self.source, self.conf = x, y, source, conf


class MotionCandidateDetector:
    """Frame-differencing/background-subtraction candidate finder."""

    def __init__(self, frame_shape):
        h, w = frame_shape[:2]
        self.frame_area = float(h * w)
        self.bg = cv2.createBackgroundSubtractorMOG2(
            history=config.BG_HISTORY, varThreshold=config.BG_VAR_THRESHOLD, detectShadows=False,
        )
        self.min_area = config.PUCK_MIN_AREA_FRAC * self.frame_area
        self.max_area = config.PUCK_MAX_AREA_FRAC * self.frame_area

    def detect(self, frame_bgr):
        gray = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2GRAY)
        fg = self.bg.apply(frame_bgr, learningRate=config.BG_LEARNING_RATE)
        fg = cv2.morphologyEx(fg, cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))
        contours, _ = cv2.findContours(fg, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

        out = []
        for c in contours:
            area = cv2.contourArea(c)
            if area < self.min_area or area > self.max_area:
                continue
            x, y, w, h = cv2.boundingRect(c)
            aspect = max(w, h) / max(1.0, min(w, h))
            if aspect > config.PUCK_MAX_ASPECT_RATIO:
                continue
            mask = np.zeros(gray.shape, dtype=np.uint8)
            cv2.drawContours(mask, [c], -1, 255, -1)
            mean_gray = cv2.mean(gray, mask=mask)[0]
            if mean_gray > config.PUCK_MAX_MEAN_GRAY:
                continue
            cx, cy = x + w / 2.0, y + h / 2.0
            # Darker and more compact -> higher confidence.
            darkness = max(0.0, (config.PUCK_MAX_MEAN_GRAY - mean_gray) / config.PUCK_MAX_MEAN_GRAY)
            compactness = 1.0 / aspect
            out.append(Candidate(cx, cy, "motion", 0.3 + 0.4 * darkness + 0.3 * compactness))
        return out


class YoloPuckCandidateDetector:
    """Optional: a custom-trained YOLO puck model, or stock COCO
    'sports ball' as a weak prior. Either way, its hits become
    high(er)-trust candidates for the same Kalman gate."""

    def __init__(self, weights_path, device="cpu", conf=0.15, is_custom=True):
        from ultralytics import YOLO
        self.model = YOLO(weights_path)
        self.device = device
        self.conf = conf
        self.classes = None if is_custom else [config.COCO_SPORTS_BALL_CLASS]
        self.is_custom = is_custom

    def detect(self, frame_bgr):
        results = self.model.predict(
            frame_bgr, device=self.device, conf=self.conf, classes=self.classes, verbose=False,
        )
        out = []
        for r in results:
            if r.boxes is None:
                continue
            for box in r.boxes:
                x1, y1, x2, y2 = box.xyxy[0].tolist()
                conf = float(box.conf[0]) if box.conf is not None else 0.5
                cx, cy = (x1 + x2) / 2.0, (y1 + y2) / 2.0
                # Custom puck-class detections are trusted more than the
                # generic "sports ball" prior.
                trust = 0.9 if self.is_custom else 0.6
                out.append(Candidate(cx, cy, "yolo", trust * conf))
        return out


class PuckTracker:
    """Fuses candidates from one or more detectors into a single tracked
    puck position via a constant-velocity Kalman filter."""

    def __init__(self, detectors):
        self.detectors = detectors
        self.kf = ConstantVelocityKalman2D(
            config.PUCK_PROCESS_NOISE_ACCEL_VAR, config.PUCK_MEASUREMENT_NOISE_VAR,
        )
        self.coast_frames = 0
        self.miss_streak = 0
        self.last_confirmed = None  # (t, x, y) of the last real measurement
        self.history = []  # list of dicts: t, x, y, vx, vy, speed, status

    def reset_track(self):
        """Drop the current track without touching history: for a jump
        in the video's own clock (a cut skipped by the worker, or a
        new --start), where the prior velocity/position has no bearing
        on what comes next and coasting across the gap would just
        produce a nonsense straight-line guess."""
        self.kf.initialised = False
        self.coast_frames = 0
        self.miss_streak = 0
        self.last_confirmed = None

    def _best_candidate(self, candidates):
        if not candidates or not self.kf.initialised:
            return None, None
        best, best_d2 = None, None
        for c in candidates:
            y, S, _K = self.kf.innovation((c.x, c.y))
            d2 = ConstantVelocityKalman2D.mahalanobis_sq(y, S)
            if d2 > config.PUCK_GATE_CHI2:
                continue
            # Among candidates inside the gate, prefer the closer one,
            # breaking ties with detector confidence.
            score = d2 - c.conf
            if best is None or score < best_d2:
                best, best_d2 = c, score
        return best, best_d2

    def step(self, frame_bgr, t_s, dt, project_fn=None):
        """project_fn, if given, maps a candidate's pixel (x, y) to the
        coordinate space the Kalman filter should track in (e.g. rink
        feet via the active RinkCalibration). Without it, tracking stays
        in raw pixel space -- fine for visualisation, but shot speeds
        then come out in px/s, not a physical unit."""
        candidates = []
        for det in self.detectors:
            candidates.extend(det.detect(frame_bgr))
        if project_fn is not None:
            for c in candidates:
                c.x, c.y = project_fn(c.x, c.y)
        self.step_with_candidates(t_s, dt, candidates)

    def step_with_candidates(self, t_s, dt, candidates):
        """Core fusion/gating/reacquisition logic, taking candidates
        already in the tracker's working coordinate space. Split out from
        step() so it can be driven directly (e.g. by tests) without a
        real frame or detectors.

        The Mahalanobis gate (config.PUCK_GATE_CHI2) is deliberately
        tight once a track is confirmed, to reject clutter -- but a real
        shot is exactly the case where the true position suddenly jumps
        far from what the constant-velocity model predicts, which a
        tight gate would reject forever (the gap only grows each coasted
        frame; it doesn't shrink). So a short run of "candidates exist
        but none are inside the gate" (miss_streak, as opposed to "no
        candidates at all", which is a real occlusion/blur and should
        just coast) triggers an immediate reseed onto the best available
        candidate instead of waiting out PUCK_MAX_COAST_FRAMES.
        """
        if not self.kf.initialised:
            # Seed from the single most isolated, confident candidate.
            if candidates:
                seed = max(candidates, key=lambda c: c.conf)
                self.kf.reset(seed.x, seed.y)
                self.coast_frames = 0
                self.miss_streak = 0
                self.last_confirmed = (t_s, seed.x, seed.y)
                status = "seeded"
            else:
                self.history.append({"t": t_s, "x": None, "y": None, "vx": 0.0, "vy": 0.0, "speed": 0.0, "status": "no_track"})
                return
        else:
            self.kf.predict(dt)
            best, _ = self._best_candidate(candidates)
            if best is not None:
                self.kf.update((best.x, best.y))
                self.coast_frames = 0
                self.miss_streak = 0
                self.last_confirmed = (t_s, best.x, best.y)
                status = "tracked"
            else:
                self.coast_frames += 1
                self.miss_streak = self.miss_streak + 1 if candidates else 0
                if self.miss_streak >= config.PUCK_REACQUIRE_AFTER_MISSES:
                    reseed = max(candidates, key=lambda c: c.conf)
                    # A reseed at vx=vy=0 would read as "slow" at a
                    # position that's actually already downstream of the
                    # true release point -- fooling the shot detector's
                    # search for "the last slow frame before the rise".
                    # Instead, use the known gap (last confirmed
                    # position/time vs. this one) to seed a real implied
                    # velocity, which is also a better estimate on its
                    # own merits: we know exactly how far the puck moved
                    # and over how long.
                    vx0, vy0 = 0.0, 0.0
                    if self.last_confirmed is not None:
                        t0, x0, y0 = self.last_confirmed
                        gap = t_s - t0
                        if gap > 1e-6:
                            vx0, vy0 = (reseed.x - x0) / gap, (reseed.y - y0) / gap
                    self.kf.reset(reseed.x, reseed.y, vx=vx0, vy=vy0)
                    self.coast_frames = 0
                    self.miss_streak = 0
                    self.last_confirmed = (t_s, reseed.x, reseed.y)
                    status = "reacquired"
                else:
                    status = "coasting" if self.coast_frames <= config.PUCK_MAX_COAST_FRAMES else "lost"
                    if status == "lost":
                        self.kf.initialised = False

        if self.kf.initialised:
            x, y = self.kf.position
            vx, vy = self.kf.velocity
            self.history.append({"t": t_s, "x": x, "y": y, "vx": vx, "vy": vy, "speed": self.kf.speed, "status": status})
        else:
            self.history.append({"t": t_s, "x": None, "y": None, "vx": 0.0, "vy": 0.0, "speed": 0.0, "status": "lost"})
