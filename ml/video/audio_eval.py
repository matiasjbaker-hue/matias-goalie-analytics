"""Audio test driver: embed every film's candidates on Modal, then check whether
sound separates real shots from the round-4 model's near-misses.

    ml/.venv/bin/python ml/video/audio_candidates.py         # once: labelled candidates
    ml/.venv/bin/python ml/video/audio_eval.py --smoke       # one film, sanity check
    modal deploy ml/video/audio_modal.py                     # once
    ml/.venv/bin/python ml/video/audio_eval.py --launch      # all films in the cloud (~$3-4); laptop can sleep
    ml/.venv/bin/python ml/video/audio_eval.py --collect     # later: download to ml/data/audio/emb/
    ml/.venv/bin/python ml/video/audio_eval.py --eval        # cross-validated by goalie

Folds are the same whole-goalie folds as the video model, and the model score
used is the cross-validated one, so nothing here has seen its test goalie.
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
REPO = Path(__file__).resolve().parents[2]
DIR = REPO / "ml" / "data" / "audio"
EMB = DIR / "emb"
CANDS = DIR / "candidates.json"


def save(res):
    EMB.mkdir(parents=True, exist_ok=True)
    v = res["video_id"]
    if not res.get("has_audio"):
        np.savez(EMB / f"{v}.npz", has_audio=False)
        return
    w = res["windows"]
    np.savez(EMB / f"{v}.npz", has_audio=True, film_rms=res["film_rms"],
             emb_at=w["at"]["emb"], emb_after=w["after"]["emb"],
             prob_at=w["at"]["prob"], prob_after=w["after"]["prob"],
             rms_at=w["at"]["rms"], rms_after=w["after"]["rms"])
    (DIR / "labels.json").write_text(json.dumps(res["labels"]))


def launch():
    """Spawn every film on the deployed app; results land on the volume. Safe to close the laptop after."""
    import modal
    films = json.loads(CANDS.read_text())
    fn = modal.Function.from_name("goalieiq-audio", "embed_and_save")
    have = remote_done()
    todo = {v: f for v, f in films.items() if v not in have and not (EMB / f"{v}.npz").exists()}
    for f in todo.values():
        fn.spawn(f)
    print(f"Started {len(todo)} films in the cloud ({len(films) - len(todo)} already done). "
          "Run --collect later to download.")


def remote_done():
    import modal
    try:
        return {e.path.split("/")[-1][:-4] for e in modal.Volume.from_name("goalieiq-ml").iterdir("audio/emb")
                if e.path.endswith(".pkl")}
    except Exception:
        return set()


def collect():
    import pickle
    import modal
    films = json.loads(CANDS.read_text())
    vol = modal.Volume.from_name("goalieiq-ml")
    have = remote_done()
    new = [v for v in have if not (EMB / f"{v}.npz").exists()]
    for v in new:
        save(pickle.loads(b"".join(vol.read_file(f"audio/emb/{v}.pkl"))))
    done = sum((EMB / f"{v}.npz").exists() for v in films)
    print(f"{done}/{len(films)} films downloaded ({len(new)} new)")
    return done == len(films)


def run(only=None):
    import modal
    import audio_modal as A
    films = json.loads(CANDS.read_text())
    todo = {v: f for v, f in films.items() if (only is None or v in only) and not (EMB / f"{v}.npz").exists()}
    print(f"{len(films) - len(todo)} done already; starting {len(todo)}")
    with modal.enable_output(), A.app.run():
        calls = {v: A.embed_film.spawn(f) for v, f in todo.items()}
        for n, (v, c) in enumerate(calls.items(), 1):
            try:
                res = c.get()
                save(res)
                print(f"[{n}/{len(calls)}] {v}: " + ("no audio" if not res["has_audio"] else
                      f"{len(films[v]['cands'])} candidates, {res['seconds'] / 60:.0f} min of sound"), flush=True)
            except Exception as e:
                print(f"[{n}/{len(calls)}] {v}: FAILED {e}", flush=True)


def load():
    films = json.loads(CANDS.read_text())
    rows = []
    for v, f in films.items():
        p = EMB / f"{v}.npz"
        if not p.exists():
            continue
        z = np.load(p)
        if not bool(z["has_audio"]) or not f["cands"]:
            continue
        frms = float(z["film_rms"])
        for i, c in enumerate(f["cands"]):
            rows.append(dict(v=v, fold=f["fold"], shot=c["shot"], score=c["score"],
                             emb=np.concatenate([z["emb_at"][i], z["emb_after"][i]]).astype(np.float32),
                             loud=np.log([z["rms_at"][i] / frms, z["rms_after"][i] / frms]).astype(np.float32),
                             prob=np.concatenate([z["prob_at"][i], z["prob_after"][i]]).astype(np.float32)))
    return films, rows


def curve(scores, y, n_true, hours, recalls=(0.8, 0.7, 0.6, 0.5)):
    order = np.argsort(-scores)
    tp = np.cumsum(y[order]); fp = np.cumsum(1 - y[order])
    out = {}
    for r in recalls:
        k = np.searchsorted(tp, r * n_true)
        out[r] = None if k >= len(tp) else (fp[k] / hours, tp[k] / (tp[k] + fp[k]))
    return out


def evaluate():
    from sklearn.linear_model import LogisticRegression
    from sklearn.metrics import roc_auc_score
    from sklearn.pipeline import make_pipeline
    from sklearn.preprocessing import StandardScaler

    films, rows = load()
    used = sorted({r["v"] for r in rows})
    no_audio = [v for v in films if (EMB / f"{v}.npz").exists() and not bool(np.load(EMB / f"{v}.npz")["has_audio"])]
    y = np.array([r["shot"] for r in rows]); fold = np.array([r["fold"] for r in rows])
    logit = lambda p: np.log(np.clip(p, 1e-6, 1 - 1e-6) / np.clip(1 - p, 1e-6, 1))
    m = logit(np.array([r["score"] for r in rows]))[:, None]
    A = np.stack([np.concatenate([r["emb"], r["loud"]]) for r in rows])
    n_true = sum(films[v]["n_true"] for v in used); hours = sum(films[v]["hours"] for v in used)
    print(f"{len(used)} films with sound ({len(no_audio)} without), {len(rows)} candidates, {y.sum()} real shots, "
          f"{n_true} tagged shots, {hours:.1f} h")

    def cv(X, C):
        out = np.zeros(len(y))
        for f in sorted(set(fold)):
            tr, te = fold != f, fold == f
            clf = make_pipeline(StandardScaler(), LogisticRegression(C=C, max_iter=3000, class_weight="balanced"))
            clf.fit(X[tr], y[tr])
            out[te] = clf.decision_function(X[te])
        return out

    results = {"video model only": m[:, 0]}
    for C in (0.001, 0.01):
        results[f"sound only (C={C})"] = cv(A, C)
        results[f"video + sound (C={C})"] = cv(np.hstack([m, A]), C)
    hard = np.array([r["score"] for r in rows]) >= 0.5
    lines = [f"# Audio test — can the sound separate real shots from near-misses?\n",
             f"{len(used)} games with sound, {len(rows)} moments the round-4 model flags (threshold 0.02), "
             f"{y.sum()} of them real shots; {hours:.1f} h of film. Cross-validated by whole goalie (5 folds).\n",
             "| scorer | AUC all | AUC on confident (video ≥0.5) | extras/h @80% | @70% | @60% | @50% |",
             "|---|---|---|---|---|---|---|"]
    for name, s in results.items():
        c = curve(s, y, n_true, hours)
        cell = lambda r: "—" if c[r] is None else f"{c[r][0]:.0f} ({c[r][1] * 100:.0f}%)"
        lines.append(f"| {name} | {roc_auc_score(y, s):.3f} | {roc_auc_score(y[hard], s[hard]):.3f} | "
                     + " | ".join(cell(r) for r in (0.8, 0.7, 0.6, 0.5)) + " |")
    labels = json.loads((DIR / "labels.json").read_text())
    P = np.stack([r["prob"] for r in rows])
    diff = []
    for half, off in (("at", 0), ("after", 527)):
        for i, lab in enumerate(labels):
            a, b = P[y == 1, off + i].mean(), P[y == 0, off + i].mean()
            diff.append((abs(np.log((a + 1e-4) / (b + 1e-4))), lab, half, a, b))
    diff.sort(reverse=True)
    lines += ["\nAudioSet sounds that differ most (mean score, real shots vs near-misses):\n"]
    lines += [f"- {lab} ({half}): {a:.3f} vs {b:.3f}" for _, lab, half, a, b in diff[:12]]
    report = "\n".join(lines)
    (DIR / "report.md").write_text(report + "\n")
    print(report)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--eval", action="store_true")
    ap.add_argument("--launch", action="store_true", help="spawn all films on the deployed app (survives sleep)")
    ap.add_argument("--collect", action="store_true", help="download finished films from the volume")
    args = ap.parse_args()
    if args.launch:
        launch()
    if args.collect:
        collect()
    if args.smoke:
        films = json.loads(CANDS.read_text())
        v = min(films, key=lambda v: len(films[v]["cands"]) or 1e9)
        run(only={v})
    if args.run:
        run()
    if args.eval:
        evaluate()


if __name__ == "__main__":
    main()
