"""
SHOT DETECTION — propose shot moments for a film
=================================================
    node --env-file=.env ml/detect/extract-features.mjs --all --video <id> --games <games.jsonl>
    ml/.venv/bin/python ml/detect/predict.py <video_id> [--mode review|balanced]

Reads that film's features, scores every half-second with the saved
model and prints JSON: [{"t": seconds, "score": 0..1}, ...], the same
shape the Video Review screen's "moments to check" use.
"""

import argparse
import json
import pickle
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from train import DATA, MODELS, load_segments, film_index, segment_rows, pick_peaks  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video_id")
    ap.add_argument("--mode", choices=["review", "balanced"], default="review")
    args = ap.parse_args()

    bundle = pickle.loads((MODELS / "shot_detector.pkl").read_bytes())
    model, pca, cfg = bundle["model"], bundle["pca"], bundle["config"]
    threshold = cfg["threshold_review"] if args.mode == "review" else cfg["threshold_best_f1"]

    films = film_index()
    film = films.get(str(args.video_id), {"period_marks": {}})
    segs = [s for s in load_segments() if str(s["video_id"]) == str(args.video_id)]
    if not segs:
        sys.exit(f"No features for video {args.video_id} in {DATA / 'features'}")

    out = []
    for s in sorted(segs, key=lambda s: s["start"]):
        X, t = segment_rows(s, pca, film)
        if X is None:
            continue
        pt, ps = pick_peaks(t, model.predict_proba(X)[:, 1], threshold)
        out += [{"t": round(float(a), 1), "score": round(float(b), 3)} for a, b in zip(pt, ps)]
    print(json.dumps(out))


if __name__ == "__main__":
    main()
