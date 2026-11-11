"""
Start round-2 GPU jobs on the *deployed* Modal app, so they keep running
even if this Mac sleeps or loses its connection. Collect results later.

    ml/.venv/bin/modal deploy ml/video/shots_modal.py        # once, after code changes
    ml/.venv/bin/python ml/video/launch.py                   # start any jobs not finished yet
    ml/.venv/bin/python ml/video/launch.py --status          # how many are done
    ml/.venv/bin/python ml/video/launch.py --report          # write ml/data/eval_video/report.md

Options: --epochs 8 --folds 5 --no-curve (100% only)
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import modal

sys.path.insert(0, str(Path(__file__).resolve().parent))
import shots_modal as S  # noqa: E402

APP = "goalieiq-shots"


def load_films():
    films = {}
    for line in (S.REPO / "ml" / "data" / "games.jsonl").read_text().splitlines():
        g = json.loads(line)
        for f in g["film"]:
            films[str(f["video_id"])] = dict(f, video_id=str(f["video_id"]), user_id=str(g["user_id"]),
                                             date=g.get("date"), opponent=g.get("opponent"))
    return films


def job_list(films, k, fold_of, fractions, epochs):
    jobs = []
    for frac in fractions:
        for f in range(k):
            test = [films[v] for v in films if fold_of[v] == f]
            train = sorted(v for v in films if fold_of[v] != f)
            if frac < 1:
                n = max(2, int(round(frac * len(train))))
                train = sorted(np.random.default_rng(100 + f).choice(train, n, replace=False).tolist())
            jobs.append((f"{int(frac * 100)}%/fold{f + 1}", train, test, epochs))
    return jobs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--epochs", type=int, default=8)
    ap.add_argument("--folds", type=int, default=5)
    ap.add_argument("--no-curve", action="store_true")
    args = ap.parse_args()

    films = load_films()
    fold_of, k = S.goalie_folds(films, args.folds)
    fractions = [1.0] if args.no_curve else [1.0, 0.5, 0.25]
    jobs = job_list(films, k, fold_of, fractions, args.epochs)

    load_scores = modal.Function.from_name(APP, "load_scores")
    done = load_scores.remote()
    done = {lab: res for lab, res in done.items() if lab in {j[0] for j in jobs}}
    todo = [j for j in jobs if j[0] not in done]
    print(f"{len(done)}/{len(jobs)} jobs finished: {sorted(done)}")

    if args.status:
        return
    if args.report:
        to_arrays = lambda res: {v: [(np.array(t), np.array(s), a, b) for t, s, a, b in segs] for v, segs in res.items()}
        results = {lab: to_arrays(res) for lab, res in done.items()}
        merged = lambda tag: {v: s for lab, res in results.items() if lab.startswith(tag + "/") for v, s in res.items()}
        out_dir = S.REPO / "ml" / "data" / "eval_video"
        heads = []
        for frac in fractions:
            tag = f"{int(frac * 100)}%"
            n_folds = sum(lab.startswith(tag + "/") for lab in results)
            if not n_folds:
                continue
            n_films = int(round(frac * len(films) * (k - 1) / k))
            h, _ = S.evaluate_core(merged(tag), films, out_dir / f"data_{tag[:-1]}pct",
                                   f"Shot detection, video model ({tag} of training games)")
            heads.append((f"{tag} (~{n_films} films){'' if n_folds == k else f', {n_folds}/{k} folds'}", h))
        if not merged("100%"):
            sys.exit("No 100% results yet.")
        _, head = S.evaluate_core(merged("100%"), films, out_dir, "Shot detection — video model (round 2)",
                                  curve=heads if len(heads) > 1 else None)
        print(head)
        print(f"\nReport: {out_dir / 'report.md'}")
        return

    if not todo:
        print("Nothing to start. Run with --report.")
        return
    train_and_score = modal.Function.from_name(APP, "train_and_score")
    for job in todo:
        call = train_and_score.spawn(*job)
        print(f"started {job[0]}: {call.object_id}")
    print(f"\n{len(todo)} jobs running in the cloud. Safe to close the laptop. "
          f"Check with: ml/.venv/bin/python ml/video/launch.py --status")


if __name__ == "__main__":
    main()
