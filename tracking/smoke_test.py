"""
Self-contained correctness check that needs no real hockey footage and no
YOLO weights download: synthesizes a puck-only trajectory (slow drift,
then a sharp acceleration toward a net) and confirms the Kalman tracker
follows it (including through a simulated detection dropout) and that
the shot detector fires on the release with a plausible speed/direction,
and does NOT fire during the slow drift.

This validates the math (Kalman gating/coasting, homography round-trip,
shot trajectory logic) end-to-end. It does NOT validate real-world
detection accuracy -- that requires actual game footage; see README.md.

Run: python smoke_test.py
"""

import math
import sys

import numpy as np

from config import RinkGeometry
from rink import RinkCalibration, CalibrationSet, CALIBRATION_ORDER, reference_points
from kalman import ConstantVelocityKalman2D
from puck_tracker import PuckTracker, Candidate
from shot_detector import detect_shots
import config


class FakePlayerTracker:
    def __init__(self, track_positions):
        self.track_positions = track_positions


def make_calibration():
    """Build a calibration from a made-up but internally consistent
    camera projection, so pixel_to_rink/rink_to_pixel round-trip and the
    homography math gets exercised exactly like it would from real
    clicks."""
    geo = RinkGeometry()
    ref = reference_points(geo)
    # A simple affine pixel mapping standing in for a real camera: rink
    # feet -> pixels, origin at image center, 6 px/ft, y flipped (image
    # y grows downward).
    def rink_to_px(rx, ry):
        return (640 + rx * 6.0, 360 - ry * 6.0)

    pixel_points = [rink_to_px(*ref[name]) for name in CALIBRATION_ORDER]
    calib = RinkCalibration.from_clicks(pixel_points, geo, start_s=0.0, end_s=None, side="near")
    return calib, rink_to_px


def check(name, cond):
    status = "OK " if cond else "FAIL"
    print(f"[{status}] {name}")
    return cond


def main():
    ok = True
    calib, rink_to_px = make_calibration()
    cs = CalibrationSet([calib])

    # Round-trip sanity: a known rink point should survive pixel->rink->pixel.
    gx, gy = calib.goal_mouth_center()
    px, py = rink_to_px(gx, gy)
    rx, ry = calib.pixel_to_rink(px, py)
    ok &= check("homography round-trips goal mouth", math.hypot(rx - gx, ry - gy) < 0.5)

    # --- synthetic puck trajectory, in rink feet ---
    # Starts at the blue line, drifts slowly for 1s, then a shot fires
    # straight at the net for the next 0.3s, reaching ~70 ft/s (~48 mph),
    # with a 5-frame dropout right after release to exercise coasting.
    fps = 30.0
    dt = 1.0 / fps
    frames = []
    t = 0.0
    x, y = 60.0, 10.0  # near blue line, off to one side of the net
    vx, vy = -3.0, -1.0  # slow drift
    for i in range(int(1.0 * fps)):
        x += vx * dt
        y += vy * dt
        frames.append((t, x, y, "player"))
        t += dt

    # Release: aim straight at the goal mouth center at high speed.
    gx, gy = calib.goal_mouth_center()
    dirx, diry = gx - x, gy - y
    norm = math.hypot(dirx, diry)
    dirx, diry = dirx / norm, diry / norm
    shot_speed = 70.0
    shooter_pos = (x, y)
    for i in range(int(0.5 * fps)):
        x += dirx * shot_speed * dt
        y += diry * shot_speed * dt
        frames.append((t, x, y, "shot"))
        t += dt

    # --- feed it through the real PuckTracker.step_with_candidates (the
    # exact fusion/gating/reacquisition code pipeline.py drives), with
    # candidates pre-projected to rink feet exactly as pipeline.py's
    # project_fn would, and a 5-frame dropout to test coasting. ---
    tracker = PuckTracker(detectors=[])  # candidates are injected directly below
    dropout = set(range(int(1.0 * fps), int(1.0 * fps) + 5))
    for i, (t_s, rx_f, ry_f, _label) in enumerate(frames):
        pxp, pyp = rink_to_px(rx_f, ry_f)
        if i in dropout:
            candidates = []
        else:
            rxk, ryk = calib.pixel_to_rink(pxp, pyp)
            candidates = [Candidate(rxk, ryk, "synthetic", 1.0)]
        tracker.step_with_candidates(t_s, dt, candidates)

    # Kalman should have tracked through the dropout without losing lock.
    statuses = [h["status"] for h in tracker.history]
    ok &= check("no 'lost' track despite the 5-frame dropout", "lost" not in statuses)
    ok &= check("tracker coasted through the dropout", "coasting" in statuses)

    # The filter is reseeded at vx=vy=0 on reacquisition (by design -- it
    # has no basis to guess a direction), so it climbs toward the true
    # 70 ft/s release speed over the next few frames rather than hitting
    # it instantly. Being clearly above the pre-release drift (~3 ft/s)
    # is what matters here; exact convergence isn't.
    final_speed_ftps = tracker.history[-1]["speed"]
    ok &= check(f"final tracked speed shows the release, not the drift (got {final_speed_ftps:.1f} ft/s, drift was ~3, true shot speed 70)",
                40.0 <= final_speed_ftps <= 85.0)

    # --- shot detection ---
    # A real shooter doesn't teleport away the instant the puck leaves
    # their stick, so give the fake player several samples straddling
    # the drift->release transition (covers whenever detection actually
    # fires within that span).
    players = FakePlayerTracker({
        1: [(frames[i][0], *rink_to_px(*shooter_pos)) for i in range(20, len(frames))],
    })
    shots = detect_shots(tracker.history, cs, players)
    ok &= check(f"exactly one shot detected (got {len(shots)})", len(shots) == 1)
    if shots:
        s = shots[0].to_dict()
        print("  shot:", s)
        ok &= check("shooter attributed to the nearby player track", s["shooter_track_id"] == 1)
        ok &= check("direction is tight (aimed at net)", s["direction_deg_to_net"] < 10.0)
        ok &= check("speed is in a plausible shot range (30-90 mph)", 30.0 <= s["speed_mph"] <= 90.0)

    # Slow drift alone (no release) should not trigger a shot.
    drift_only = tracker.history[: int(1.0 * fps)]
    drift_shots = detect_shots(drift_only, cs, players)
    ok &= check("no shot fires during the slow drift phase alone", len(drift_shots) == 0)

    print("\nALL CHECKS PASSED" if ok else "\nSOME CHECKS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
