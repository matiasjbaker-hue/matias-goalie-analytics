"""
Start round-2 GPU jobs on the *deployed* Modal app, so they keep running
even if this Mac sleeps or loses its connection. Collect results later.

    ml/.venv/bin/modal deploy ml/video/shots_modal.py        # once, after code changes
    ml/.venv/bin/python ml/video/launch.py                   # start any jobs not finished yet
    ml/.venv/bin/python ml/video/launch.py --status          # how many are done
    ml/.venv/bin/python ml/video/launch.py --report          # write ml/data/eval_video/report.md

    ml/.venv/bin/python ml/video/launch.py --final            # train the model the site's Review button uses

Round 5 (sharper net-side crop + the round-4 model's mistakes as "no shot" examples):
    ml/.venv/bin/python ml/video/launch.py --mine                                  # free: reads round-4 scores
    ml/.venv/bin/python ml/video/launch.py --net --variant r5 --prepare            # cut sharper clips (~$4)
    ml/.venv/bin/python ml/video/launch.py --net --variant r5 --run r5 --only 1,2,3   # then 4,5, then --report

Options: --epochs 8 --folds 5 --no-curve (100% only)
         --net  mirror clips so the tracked net is always on the left
                (uses ml/video/net_sides.json; 100% data only; results kept
                apart from round 2 under "net100%/...", report in eval_video_net/)
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


HARD_NEGS = S.REPO / "ml" / "data" / "hard_negs_r4.json"


HOLDOUT = S.REPO / "ml" / "data" / "holdout.json"   # {"video_ids": [...], "why": ...}: never trained on


def load_films(net=False, variant="r4"):
    sides = json.loads((Path(__file__).resolve().parent / "net_sides.json").read_text()) if net else {}
    held = set(map(str, json.loads(HOLDOUT.read_text()).get("video_ids", []))) if HOLDOUT.exists() else set()
    films = {}
    for line in (S.REPO / "ml" / "data" / "games.jsonl").read_text().splitlines():
        g = json.loads(line)
        for f in g["film"]:
            if str(f["video_id"]) in held:             # kept for honest tests only
                continue
            films[str(f["video_id"])] = dict(f, video_id=str(f["video_id"]), user_id=str(g["user_id"]),
                                             date=g.get("date"), opponent=g.get("opponent"),
                                             net_sides=sides.get(str(f["video_id"])))
    if variant != "r4":
        hard = json.loads(HARD_NEGS.read_text()) if HARD_NEGS.exists() else {}
        if not hard:
            sys.exit("No mined mistakes yet: run with --mine first.")
        for v, f in films.items():
            f["hard_negs"] = hard.get(v, [])
    return films


def mine_hard_negatives(threshold=0.2):
    """The round-4 model's mistakes on every film (each scored by a model that never saw it):
    peaks above threshold at least HARD_NEG_MIN_DIST s from any tagged shot. The strongest,
    up to one per tagged shot (at least 5), become extra "no shot" examples for round 5."""
    films = load_films(True)
    done = modal.Function.from_name(APP, "load_scores").remote()
    out, total = {}, 0
    for lab, res in done.items():
        if not lab.startswith("r4net100%/"):
            continue
        for v, segs in res.items():
            shots = films.get(v, {}).get("shot_times") or []
            cand = []
            for t, sc, a, b in segs:
                pt, ps = S.pick_peaks(np.array(t), np.array(sc), threshold)
                d = S.nearest_dist(pt, shots)
                cand += [(float(s_), float(t_)) for t_, s_, dd in zip(pt, ps, d) if dd >= S.HARD_NEG_MIN_DIST]
            cand.sort(reverse=True)
            out[v] = sorted(round(t_, 2) for _, t_ in cand[: max(5, len(shots))])
            total += len(out[v])
    if len(out) < len(films):
        sys.exit(f"Round-4 scores cover {len(out)} of {len(films)} films; finish round 4 first.")
    HARD_NEGS.write_text(json.dumps(out))
    print(f"Mined {total} mistakes across {len(out)} films -> {HARD_NEGS}")


def job_list(films, k, fold_of, fractions, epochs, net=False, run="", variant="r4"):
    jobs = []
    for frac in fractions:
        for f in range(k):
            test = [films[v] for v in films if fold_of[v] == f]
            train = sorted(v for v in films if fold_of[v] != f)
            if frac < 1:
                n = max(2, int(round(frac * len(train))))
                train = sorted(np.random.default_rng(100 + f).choice(train, n, replace=False).tolist())
            label = f"{run}{'net' if net else ''}{int(frac * 100)}%/fold{f + 1}"
            extra = (None, {v: films[v] for v in train}, True, variant) if net else ()
            jobs.append((label, train, test, epochs, *extra))
    return jobs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--epochs", type=int, default=8)
    ap.add_argument("--folds", type=int, default=5)
    ap.add_argument("--no-curve", action="store_true")
    ap.add_argument("--net", action="store_true")
    ap.add_argument("--only", default="", help="comma-separated fold numbers to start, e.g. 1,2,3")
    ap.add_argument("--run", default="", help="name prefix for this run's results, e.g. r4 (keeps older runs apart)")
    ap.add_argument("--prepare", action="store_true", help="cut clips for films not prepared yet, then exit")
    ap.add_argument("--final", action="store_true", help="train the model the site uses on every film (~$2), then exit")
    ap.add_argument("--variant", default="r4", choices=sorted(S.VARIANTS), help="r5: sharper net-side crop + mined mistakes")
    ap.add_argument("--mine", action="store_true", help="save the round-4 model's mistakes for round 5, then exit")
    args = ap.parse_args()

    if args.mine:
        mine_hard_negatives()
        return
    if args.variant != "r4" and not args.net:
        sys.exit("--variant r5 needs --net (the crop follows the tracked net).")
    films = load_films(args.net, args.variant)
    fold_of, k = S.goalie_folds(films, args.folds)
    fractions = [1.0] if (args.no_curve or args.net) else [1.0, 0.5, 0.25]
    if "_" in args.run or "/" in args.run:
        sys.exit("--run must not contain _ or /")
    if args.final:
        films = load_films(True)
        call = modal.Function.from_name(APP, "train_final").spawn(films, args.epochs)
        print(f"Training the site's model on {len(films)} films in the cloud ({call.object_id}).\n"
              "About 45 minutes; it's saved as ckpt/final.pt on the volume and used from the next scan on.")
        return
    if args.prepare:
        sub = S.VARIANTS[args.variant]["sub"]
        try:
            entries = modal.Volume.from_name("goalieiq-ml").iterdir(f"{sub}/windows" if sub else "windows")
            done_ids = {e.path.split("/")[-1][:-5] for e in entries if e.path.endswith(".json")}
        except Exception:      # folder not made yet: nothing prepared
            done_ids = set()
        todo = [f for v, f in films.items() if v not in done_ids]
        print(f"{len(films) - len(todo)} films already prepared; starting {len(todo)}")
        prep = modal.Function.from_name(APP, "prepare_film")
        for f in todo:
            prep.spawn(f, args.variant)
        print("Running in the cloud. Re-run with --prepare to see what's left.")
        return
    jobs = job_list(films, k, fold_of, fractions, args.epochs, args.net, args.run, args.variant)
    pre = args.run + ("net" if args.net else "")

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
        merged = lambda tag: {v: s for lab, res in results.items() if lab.startswith(pre + tag + "/") for v, s in res.items()}
        out_dir = S.REPO / "ml" / "data" / ((f"eval_video_{args.run}" if args.run else "eval_video") + ("_net" if args.net else ""))
        heads = []
        for frac in fractions:
            tag = f"{int(frac * 100)}%"
            n_folds = sum(lab.startswith(pre + tag + "/") for lab in results)
            if not n_folds:
                continue
            n_films = int(round(frac * len(films) * (k - 1) / k))
            h, _ = S.evaluate_core(merged(tag), films, out_dir / f"data_{tag[:-1]}pct",
                                   f"Shot detection, video model ({tag} of training games)")
            heads.append((f"{tag} (~{n_films} films){'' if n_folds == k else f', {n_folds}/{k} folds'}", h))
        if not merged("100%"):
            sys.exit("No 100% results yet.")
        rnd = args.run[1:] if args.run[:1] == "r" and args.run[1:].isdigit() else ("3" if args.net else "2")
        title = (f"Shot detection — video model, tracked net mirrored to the left (round {rnd})" if args.net
                 else f"Shot detection — video model (round {rnd})")
        _, head = S.evaluate_core(merged("100%"), films, out_dir, title,
                                  curve=heads if len(heads) > 1 else None)
        print(head)
        print(f"\nReport: {out_dir / 'report.md'}")
        return

    if not todo:
        print("Nothing to start. Run with --report.")
        return
    if args.only:
        wanted = {f"fold{n.strip()}" for n in args.only.split(",")}
        todo = [j for j in todo if j[0].split("/")[-1] in wanted]
    train_and_score = modal.Function.from_name(APP, "train_and_score")
    for job in todo:
        call = train_and_score.spawn(*job)
        print(f"started {job[0]}: {call.object_id}")
    print(f"\n{len(todo)} jobs running in the cloud. Safe to close the laptop. "
          f"Check with: ml/.venv/bin/python ml/video/launch.py --status")


if __name__ == "__main__":
    main()
