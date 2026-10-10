"""
Integration check for pipeline.run()'s multi-range scanning (the path
the worker depends on: ranges computed from admin-marked cuts, plus
progress reporting back to the site). Needs the full requirements.txt
(opencv + ultralytics) and a real video file, unlike smoke_test.py
(which deliberately avoids both) -- this is the price of testing actual
cv2.VideoCapture seeking behaviour rather than just the tracking math.

Builds a short synthetic video, scans two disjoint ranges with a gap
between them, and checks: the gap was actually skipped (processed
duration matches the ranges, not the whole file), progress reaches 1.0
monotonically, and nothing crashes with calibration=None/out_json=None
(the worker's typical call shape before a calibration exists).

Run: python pipeline_smoke_test.py
"""
import os
import sys
import tempfile

import cv2
import numpy as np

from pipeline import run

FPS = 10
TOTAL_SECONDS = 4


def make_synthetic_video(path):
    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    writer = cv2.VideoWriter(path, fourcc, FPS, (320, 240))
    for i in range(FPS * TOTAL_SECONDS):
        frame = np.full((240, 320, 3), 200, dtype=np.uint8)  # light "ice"
        cx = 20 + (i * 6) % 280
        cv2.circle(frame, (cx, 120), 4, (20, 20, 20), -1)
        writer.write(frame)
    writer.release()


def check(name, cond):
    print(f"[{'OK ' if cond else 'FAIL'}] {name}")
    return cond


def main():
    ok = True
    tmp_dir = tempfile.mkdtemp(prefix="yolo_pipeline_smoke_")
    video_path = os.path.join(tmp_dir, "synthetic.mp4")
    make_synthetic_video(video_path)

    progress_calls = []
    report = run(
        video_path=video_path,
        out_json=None,
        calibration=None,
        ranges=[(0.0, 1.0), (2.0, 3.0)],  # skips [1,2) and [3,4)
        device="cpu",
        stride=1,
        log_every=5,
        progress_cb=lambda f: progress_calls.append(f),
    )

    ok &= check("progress_cb was called", len(progress_calls) > 0)
    ok &= check(f"progress is monotonically non-decreasing (got {progress_calls})",
                all(b >= a - 1e-9 for a, b in zip(progress_calls, progress_calls[1:])))
    ok &= check(f"progress reaches 1.0 at the end (got {progress_calls[-1] if progress_calls else None})",
                bool(progress_calls) and abs(progress_calls[-1] - 1.0) < 1e-6)

    # Two 1-second ranges scanned -> ~2s processed, NOT the whole 4s file
    # (which is what we'd get if the gap between them wasn't skipped).
    ok &= check(f"processed duration reflects the two ranges, not the whole file (got {report['duration_s']}s, want ~2.0s)",
                1.8 <= report["duration_s"] <= 2.2)
    ok &= check("report has no calibration (ran uncalibrated, as the worker would before setup)",
                report["calibrated"] is False)
    ok &= check("no crash with calibration=None and out_json=None", True)

    print("\nALL CHECKS PASSED" if ok else "\nSOME CHECKS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
