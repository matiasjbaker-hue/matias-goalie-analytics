"""
Interactive rink calibration tool.

Grabs a frame from your video, shows it in a window, and has you click
six rink markings in a fixed order (skip an occluded one with 's', undo
the last click with 'u'). Writes a calibration JSON that pipeline.py
will use to convert pixel positions to real rink coordinates in feet.

Usage:
    python rink_calibrate.py --video game.mp4 --t 12.0 --out game_calibration.json
    # add more segments later (e.g. camera moved at 40 min):
    python rink_calibrate.py --video game.mp4 --t 2450 --out game_calibration.json \
        --start 2430 --append

Click order (cancel/skip a step with 's' if that marking isn't visible):
  1. goal post - near side   (the post on your left as you face the net)
  2. goal post - far side
  3. defensive faceoff dot - near side
  4. defensive faceoff dot - far side
  5. blue line x near-side board
  6. blue line x far-side board
"""

import argparse
import os
import sys

import cv2

from config import RinkGeometry
from rink import RinkCalibration, CalibrationSet, CALIBRATION_ORDER

STEP_LABELS = {
    "goal_post_near": "Goal post - NEAR side",
    "goal_post_far": "Goal post - FAR side",
    "faceoff_dot_near": "Defensive faceoff dot - NEAR side",
    "faceoff_dot_far": "Defensive faceoff dot - FAR side",
    "blue_line_near_board": "Blue line x boards - NEAR side",
    "blue_line_far_board": "Blue line x boards - FAR side",
}


def grab_frame(video_path, t_s):
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise SystemExit(f"Could not open video: {video_path}")
    cap.set(cv2.CAP_PROP_POS_MSEC, t_s * 1000.0)
    ok, frame = cap.read()
    cap.release()
    if not ok or frame is None:
        raise SystemExit(f"Could not read a frame at t={t_s}s. Try a different timestamp.")
    return frame


def run_clicker(frame):
    points = [None] * len(CALIBRATION_ORDER)
    idx = 0
    win = "Rink calibration - click markings, s=skip, u=undo, q=quit"
    cv2.namedWindow(win, cv2.WINDOW_NORMAL)

    def redraw():
        disp = frame.copy()
        for i, p in enumerate(points):
            if p is not None:
                cv2.circle(disp, (int(p[0]), int(p[1])), 5, (0, 255, 255), -1)
                cv2.putText(disp, str(i + 1), (int(p[0]) + 8, int(p[1]) - 8),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
        if idx < len(CALIBRATION_ORDER):
            label = STEP_LABELS[CALIBRATION_ORDER[idx]]
            cv2.putText(disp, f"Click: {label}  (s=skip, u=undo, q=done/quit)",
                        (16, 32), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)
        else:
            cv2.putText(disp, "All points placed. Press q to save.",
                        (16, 32), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 200, 0), 2)
        cv2.imshow(win, disp)

    def on_click(event, x, y, flags, userdata):
        nonlocal idx
        if event == cv2.EVENT_LBUTTONDOWN and idx < len(CALIBRATION_ORDER):
            points[idx] = (x, y)
            idx += 1
            redraw()

    cv2.setMouseCallback(win, on_click)
    redraw()
    while True:
        key = cv2.waitKey(20) & 0xFF
        if key == ord("q"):
            break
        if key == ord("s") and idx < len(CALIBRATION_ORDER):
            points[idx] = None
            idx += 1
            redraw()
        if key == ord("u") and idx > 0:
            idx -= 1
            points[idx] = None
            redraw()
    cv2.destroyWindow(win)
    return points


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", required=True)
    ap.add_argument("--t", type=float, default=0.0, help="Timestamp (s) of a clear, representative frame.")
    ap.add_argument("--out", required=True, help="Calibration JSON path.")
    ap.add_argument("--start", type=float, default=0.0, help="Start of this calibration's validity window (s).")
    ap.add_argument("--end", type=float, default=None, help="End of this calibration's validity window (s), omit for open-ended.")
    ap.add_argument("--side", default="near", choices=["near", "far"], help="Which net this calibration covers.")
    ap.add_argument("--append", action="store_true", help="Add to an existing calibration file instead of overwriting it.")
    ap.add_argument("--length-ft", type=float, default=200.0)
    ap.add_argument("--width-ft", type=float, default=85.0)
    args = ap.parse_args()

    frame = grab_frame(args.video, args.t)
    points = run_clicker(frame)
    n_given = sum(1 for p in points if p is not None)
    if n_given < 4:
        raise SystemExit(f"Only {n_given} points placed; need at least 4 (and they must not be collinear).")

    geo = RinkGeometry(length_ft=args.length_ft, width_ft=args.width_ft)
    calib = RinkCalibration.from_clicks(points, geo, start_s=args.start, end_s=args.end, side=args.side)

    existing = []
    if args.append and os.path.exists(args.out):
        existing = CalibrationSet.load(args.out).calibrations
    CalibrationSet(existing + [calib]).save(args.out)
    print(f"Saved calibration to {args.out} (window [{args.start}, {args.end or 'end'}), side={args.side}).")


if __name__ == "__main__":
    sys.exit(main())
