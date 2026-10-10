"""
Orchestrates one pass over a video: player tracking (YOLO + ByteTrack),
puck tracking (motion detector [+ optional YOLO puck model] + Kalman
filter), rink calibration lookup per-frame, and shot detection over the
finished puck trajectory. Writes a JSON report and, optionally, an
annotated video for visual sanity-checking.
"""

import json
import time

import cv2

from player_tracker import PlayerTracker
from puck_tracker import PuckTracker, MotionCandidateDetector, YoloPuckCandidateDetector
from shot_detector import detect_shots
from rink import CalibrationSet

COLORS = [(66, 135, 245), (52, 168, 83), (251, 188, 5), (234, 67, 53), (154, 76, 224), (0, 172, 193)]


def _color_for(track_id):
    return COLORS[int(track_id) % len(COLORS)]


def run(
    video_path,
    out_json=None,
    calibration_path=None,
    calibration=None,
    ranges=None,
    annotate_path=None,
    player_weights="yolov8n.pt",
    puck_weights=None,
    puck_weights_is_custom=True,
    device="cpu",
    start_s=0.0,
    end_s=None,
    stride=1,
    show=False,
    log_every=100,
    progress_cb=None,
):
    """calibration, if given, is a prebuilt rink.CalibrationSet and takes
    precedence over calibration_path (the worker fetches one over the
    network rather than reading a local file). ranges, if given, is a
    list of (start_s, end_s) windows to scan -- e.g. the video's
    duration minus admin-marked cuts -- processed in order, seeking
    between them; the puck tracker is reset at each boundary, since
    whatever it was tracking before a skipped gap has no bearing on
    what's on the other side of it. Without ranges, the single
    start_s/end_s window is used (unchanged CLI behaviour).
    progress_cb(fraction), if given, is called periodically with how far
    through the total scanned duration (not the whole file) this run is.
    """
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise SystemExit(f"Could not open video: {video_path}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    video_duration = (total_frames / fps) if (fps and total_frames) else None

    calibration_set = calibration if calibration is not None else (
        CalibrationSet.load(calibration_path) if calibration_path else None
    )
    if calibration_set is None:
        print("WARNING: no calibration given. Puck tracking will run in pixel space and "
              "shot detection (which needs real speed/direction) will be skipped. "
              "Run rink_calibrate.py first for real results.")

    player_tracker = PlayerTracker(weights=player_weights, device=device)

    puck_detectors = [MotionCandidateDetector((height, width))]
    if puck_weights:
        puck_detectors.append(YoloPuckCandidateDetector(puck_weights, device=device, is_custom=puck_weights_is_custom))
    puck_tracker = PuckTracker(puck_detectors)

    writer = None
    if annotate_path:
        fourcc = cv2.VideoWriter_fourcc(*"mp4v")
        writer = cv2.VideoWriter(annotate_path, fourcc, fps / max(1, stride), (width, height))

    scan_ranges = list(ranges) if ranges else [(start_s, end_s)]
    resolved_ranges = [(max(0.0, s), video_duration if e is None else e) for s, e in scan_ranges]
    # Falls back to the whole file's duration (imprecise if ranges skip
    # cuts, but still moving) rather than never reporting progress at
    # all when a streamed URL's frame count can't be read up front.
    total_scan_seconds = sum(max(0.0, e - s) for s, e in resolved_ranges if e is not None) or video_duration or None

    dt = stride / fps
    puck_trail = []  # recent pixel positions, for the annotated-video trail
    t0 = time.time()
    frames_done = 0
    seconds_done = 0.0

    for range_idx, (r_start, r_end) in enumerate(resolved_ranges):
        if range_idx > 0:
            puck_tracker.reset_track()
        cap.set(cv2.CAP_PROP_POS_MSEC, r_start * 1000.0)
        frame_idx = 0
        # Prior ranges are fully done by the time we get here, so their
        # whole span counts; only the current range is partial.
        prior_seconds = sum(max(0.0, e - s) for s, e in resolved_ranges[:range_idx] if e is not None)

        while True:
            if not cap.grab():
                break
            t_s = r_start + frame_idx / fps
            if r_end is not None and t_s >= r_end:
                break
            if frame_idx % stride != 0:
                frame_idx += 1
                continue
            ok, frame = cap.retrieve()
            if not ok:
                break

            calib = calibration_set.for_time(t_s) if calibration_set else None
            project_fn = calib.pixel_to_rink if calib else None

            players = player_tracker.step(frame, t_s)
            puck_tracker.step(frame, t_s, dt, project_fn=project_fn)

            if writer is not None or show:
                disp = frame.copy()
                for p in players:
                    x1, y1, x2, y2 = [int(v) for v in p["bbox"]]
                    color = _color_for(p["track_id"])
                    cv2.rectangle(disp, (x1, y1), (x2, y2), color, 2)
                    cv2.putText(disp, f"#{p['track_id']}", (x1, max(0, y1 - 6)),
                                cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 2)
                last = puck_tracker.history[-1] if puck_tracker.history else None
                if last and last["x"] is not None:
                    if calib is not None:
                        px, py = calib.rink_to_pixel(last["x"], last["y"])
                    else:
                        px, py = last["x"], last["y"]
                    px, py = int(px), int(py)
                    puck_trail.append((px, py))
                    puck_trail[:] = puck_trail[-20:]
                    for k in range(1, len(puck_trail)):
                        cv2.line(disp, puck_trail[k - 1], puck_trail[k], (0, 0, 255), 2)
                    ring_color = (0, 0, 255) if last["status"] == "tracked" else (0, 165, 255)
                    cv2.circle(disp, (px, py), 6, ring_color, 2)
                if writer is not None:
                    writer.write(disp)
                if show:
                    cv2.imshow("tracking", disp)
                    if cv2.waitKey(1) & 0xFF == ord("q"):
                        break

            frame_idx += 1
            frames_done += 1
            seconds_done = prior_seconds + max(0.0, t_s - r_start)
            if log_every and frames_done % log_every == 0:
                elapsed = time.time() - t0
                fps_proc = frames_done / elapsed if elapsed > 0 else 0.0
                frac = (seconds_done / total_scan_seconds) if total_scan_seconds else None
                pct = f"{frac * 100:.1f}%" if frac is not None else "?%"
                print(f"range {range_idx + 1}/{len(resolved_ranges)}  t={t_s:.1f}s  ({pct})  {fps_proc:.1f} fps processed")
                if progress_cb and frac is not None:
                    progress_cb(min(1.0, frac))

    cap.release()
    if writer is not None:
        writer.release()
    if show:
        cv2.destroyAllWindows()

    if progress_cb:
        progress_cb(1.0)

    shots = detect_shots(puck_tracker.history, calibration_set, player_tracker)
    goalies = player_tracker.identify_goalies(calibration_set) if calibration_set else {}

    report = {
        "video": video_path,
        "fps": fps,
        "ranges": resolved_ranges,
        "duration_s": round(seconds_done, 2),
        "calibrated": calibration_set is not None,
        "shots": [s.to_dict() for s in shots],
        "goalie_track_ids": {str(k): v for k, v in goalies.items()},
        "puck_track": [
            {k: (round(v, 3) if isinstance(v, float) else v) for k, v in h.items()}
            for h in puck_tracker.history
        ],
    }
    if out_json:
        with open(out_json, "w") as f:
            json.dump(report, f, indent=2)

    print(f"\n{len(shots)} shot(s) detected." + (f" Report: {out_json}" if out_json else "") +
          (f"  Annotated video: {annotate_path}" if annotate_path else ""))
    return report
