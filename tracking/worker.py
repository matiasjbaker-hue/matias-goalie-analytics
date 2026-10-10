"""
Background worker: polls the site for queued YOLO scans, runs the local
tracking pipeline against one, and reports shots back into the admin's
"moments to check" checklist. Leave this running on the machine that
has the game footage access you want; queue scans from the site's
Video Review tab (a "Run YOLO scan" button writes game_videos.yolo_status
='queued'), and this picks them up automatically -- no need to run
main.py by hand per video.

Setup: copy .env.example to .env in this folder and fill in SITE_URL
and YOLO_WORKER_TOKEN (the same secret set in Vercel's environment
variables). Then:
    python worker.py
and leave it running. Ctrl+C to stop.

Talks to exactly one endpoint, POST <SITE_URL>/api/admin/yolo-worker
(api/_lib/admin-yolo.js), authenticated by the shared token -- it never
holds a Supabase or R2 credential.
"""

import json
import os
import sys
import time
import traceback

# Running with no attached console (pythonw.exe, or any redirected/piped
# invocation) makes stdout fully block-buffered instead of line-buffered,
# so print()s can sit unflushed for a long time -- and vanish entirely if
# the process is ever killed rather than exiting cleanly. Force line
# buffering so worker.log actually reflects what's happening.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(line_buffering=True)
    except Exception:
        pass
import urllib.error
import urllib.request

import cv2

from pipeline import run
from rink import CalibrationSet, RinkCalibration

POLL_IDLE_SECONDS = 30
PROGRESS_MIN_INTERVAL_S = 5
REQUEST_TIMEOUT_S = 60


def _load_env_file(path):
    if not os.path.exists(path):
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def _post(site_url, token, op, **fields):
    url = f"{site_url.rstrip('/')}/api/admin/yolo-worker"
    body = json.dumps({"token": token, "op": op, **fields}).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_S) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        raise RuntimeError(f"{op} failed: HTTP {e.code} {detail[:300]}") from None
    except urllib.error.URLError as e:
        raise RuntimeError(f"{op} failed: {e}") from None


def _calibration_from_job(job):
    data = job.get("calibration")
    if not data:
        return None
    try:
        return CalibrationSet([RinkCalibration.from_dict(d) for d in data])
    except Exception as e:
        print(f"  WARNING: couldn't read this video's calibration ({e}); scanning in pixel space, no shots will be detected.")
        return None


def _open_source(url, workdir, job_id):
    """cv2's bundled ffmpeg should stream an https URL (with range
    requests) directly, same as this repo's Node side already does for
    R2 signed URLs (api/_lib/admin-twelvelabs.js's probe()). If that
    somehow doesn't open, fall back to downloading the file first --
    slower, but keeps the worker from just failing outright."""
    cap_test = cv2.VideoCapture(url)
    ok = cap_test.isOpened()
    cap_test.release()
    if ok:
        return url, None
    print("  Couldn't open the video by streaming its URL; downloading it first (slower).")
    local_path = os.path.join(workdir, f"job-{job_id}-download.mp4")
    urllib.request.urlretrieve(url, local_path)
    return local_path, local_path


def run_one_job(site_url, token, job, workdir):
    job_id = job["id"]
    calibration = _calibration_from_job(job)
    ranges = [tuple(r) for r in job["ranges"]] if job.get("ranges") else None
    video_path, downloaded_path = _open_source(job["signedUrl"], workdir, job_id)

    last_sent = [0.0]

    def progress_cb(frac):
        now = time.time()
        if now - last_sent[0] < PROGRESS_MIN_INTERVAL_S and frac < 1.0:
            return
        last_sent[0] = now
        try:
            _post(site_url, token, "progress", jobId=job_id, progress=frac)
        except Exception as e:
            print(f"  (progress report failed, continuing: {e})")

    try:
        out_json = os.path.join(workdir, f"job-{job_id}.json")
        report = run(
            video_path=video_path,
            out_json=out_json,
            calibration=calibration,
            ranges=ranges,
            device=os.environ.get("YOLO_DEVICE", "cpu"),
            player_weights=os.environ.get("YOLO_PLAYER_WEIGHTS", "yolov8n.pt"),
            puck_weights=os.environ.get("YOLO_PUCK_WEIGHTS") or None,
            stride=int(os.environ.get("YOLO_STRIDE", "1")),
            progress_cb=progress_cb,
        )
    finally:
        if downloaded_path and os.path.exists(downloaded_path):
            os.remove(downloaded_path)

    shots = [{"t_s": s["t_s"], "confidence": s["confidence"]} for s in report["shots"]]
    result = _post(site_url, token, "complete", jobId=job_id, shots=shots)
    print(f"Job {job_id}: {len(shots)} shot(s) found, {result.get('added')} added to the checklist. Local report: {out_json}")


def main():
    _load_env_file(os.path.join(os.path.dirname(__file__), ".env"))
    site_url = os.environ.get("SITE_URL", "").strip()
    token = os.environ.get("YOLO_WORKER_TOKEN", "").strip()
    if not site_url or not token:
        raise SystemExit(
            "Set SITE_URL and YOLO_WORKER_TOKEN before running the worker -- "
            "copy tracking/.env.example to tracking/.env and fill them in."
        )

    workdir = os.path.join(os.path.dirname(__file__), "worker_reports")
    os.makedirs(workdir, exist_ok=True)

    print(f"YOLO worker started. Polling {site_url} every {POLL_IDLE_SECONDS}s while idle. Ctrl+C to stop.")
    while True:
        try:
            claimed = _post(site_url, token, "claim")
        except Exception as e:
            print(f"Couldn't reach the site ({e}); retrying in {POLL_IDLE_SECONDS}s.")
            time.sleep(POLL_IDLE_SECONDS)
            continue

        job = claimed.get("job")
        if not job:
            time.sleep(POLL_IDLE_SECONDS)
            continue

        print(f"Claimed job {job['id']}. Scanning...")
        try:
            run_one_job(site_url, token, job, workdir)
        except Exception as e:
            traceback.print_exc()
            try:
                _post(site_url, token, "fail", jobId=job["id"], error=str(e)[:500])
            except Exception as e2:
                print(f"  (also failed to report the failure: {e2})")


if __name__ == "__main__":
    main()
