"""
Integration check for worker.py's HTTP side, against a local mock of
the real endpoint's contract (api/_lib/admin-yolo.js) -- NOT the real
Vercel deployment, which this environment has no credentials for. A
tiny http.server fakes claim/progress/complete and serves a synthetic
video over a real http:// URL, so this exercises the actual code path
(streaming a video from a URL, posting JSON, matching field names)
rather than mocking it away.

This proves the plumbing (request/response shapes, progress posts
arriving, a local report getting written) works. It does NOT prove the
real admin-yolo.js endpoint behaves identically -- that needs an actual
deployment; see tracking/README.md's manual verification steps for that.

Run: python worker_smoke_test.py
"""
import json
import os
import shutil
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import cv2
import numpy as np

import worker

FPS = 10
TOTAL_SECONDS = 2
TEST_TOKEN = "test-token-123"

calls = []  # records every op the mock endpoint received, for assertions


def make_synthetic_video(path):
    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    writer = cv2.VideoWriter(path, fourcc, FPS, (320, 240))
    for i in range(FPS * TOTAL_SECONDS):
        frame = np.full((240, 320, 3), 200, dtype=np.uint8)
        cv2.circle(frame, (20 + i * 5, 120), 4, (20, 20, 20), -1)
        writer.write(frame)
    writer.release()


def make_handler(video_path):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # keep test output quiet

        def do_GET(self):
            if self.path == "/synthetic.mp4":
                with open(video_path, "rb") as f:
                    data = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "video/mp4")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Accept-Ranges", "bytes")
                self.end_headers()
                self.wfile.write(data)
            else:
                self.send_response(404)
                self.end_headers()

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
            calls.append(body)
            ok = body.get("token") == TEST_TOKEN
            op = body.get("op")
            if not ok:
                self._reply(401, {"error": "Invalid worker token."})
                return
            if op == "claim":
                already_claimed = any(c.get("op") == "claim" for c in calls[:-1])
                if already_claimed:
                    self._reply(200, {"job": None})
                else:
                    self._reply(200, {"job": {
                        "id": 1,
                        "signedUrl": f"http://127.0.0.1:{self.server.server_port}/synthetic.mp4",
                        "ranges": [[0.0, 1.0]],
                        "calibration": None,
                    }})
            elif op == "progress":
                self._reply(200, {"ok": True})
            elif op == "complete":
                self._reply(200, {"ok": True, "added": len(body.get("shots", []))})
            elif op == "fail":
                self._reply(200, {"ok": True})
            else:
                self._reply(400, {"error": "Unknown operation."})

        def _reply(self, status, payload):
            data = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    return Handler


def check(name, cond):
    print(f"[{'OK ' if cond else 'FAIL'}] {name}")
    return cond


def main():
    ok = True
    tmp_dir = tempfile.mkdtemp(prefix="yolo_worker_smoke_")
    video_path = os.path.join(tmp_dir, "synthetic.mp4")
    make_synthetic_video(video_path)

    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(video_path))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    site_url = f"http://127.0.0.1:{server.server_port}"

    try:
        claimed = worker._post(site_url, TEST_TOKEN, "claim")
        ok &= check("claim returned a job", bool(claimed.get("job")))
        job = claimed["job"]

        workdir = os.path.join(tmp_dir, "reports")
        os.makedirs(workdir, exist_ok=True)
        worker.run_one_job(site_url, TEST_TOKEN, job, workdir)

        progress_calls = [c for c in calls if c.get("op") == "progress"]
        complete_calls = [c for c in calls if c.get("op") == "complete"]
        ok &= check("at least one progress post was sent", len(progress_calls) >= 1)
        ok &= check("a complete post was sent with this job's id", any(c.get("jobId") == 1 for c in complete_calls))
        ok &= check("complete's shots field is a list (shape admin-yolo.js expects)",
                     isinstance(complete_calls[-1].get("shots"), list) if complete_calls else False)
        ok &= check("a local report file was written", os.path.exists(os.path.join(workdir, "job-1.json")))

        # Wrong token must be rejected the same way the real endpoint would.
        try:
            worker._post(site_url, "wrong-token", "claim")
            ok &= check("wrong token is rejected", False)
        except RuntimeError as e:
            ok &= check("wrong token is rejected", "401" in str(e))
    finally:
        server.shutdown()
        shutil.rmtree(tmp_dir, ignore_errors=True)

    print("\nALL CHECKS PASSED" if ok else "\nSOME CHECKS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
