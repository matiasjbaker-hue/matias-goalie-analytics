"""
SHOT DETECTION — train + honest evaluation on the tagged films
================================================================
    ml/.venv/bin/python ml/detect/train.py [--folds 5] [--quick]

Reads ml/data/games.jsonl (shot times from Video Review) and the
features from ml/detect/extract-features.mjs, then:

1. Builds one row per half-second of live film: what the frame looks
   like (Vision embedding, PCA-reduced), how things move (motion grid),
   and the motion pattern over the surrounding ~10 s.
2. Labels a row "shot" when a tagged shot is within 0.75 s of it.
3. Cross-validates with whole goalies held out (a model never sees the
   goalie, rink or camera it is scored on), turns each film's scores into
   shot times (peak picking), and matches them to the tagged shots
   within +/- 2 s.
4. Trains the final model on everything and saves it with the operating
   thresholds chosen in step 3.

Writes ml/models/shot_detector.pkl and ml/data/eval/ (report.md, plus
per-film CSVs of found / missed / extra shots for spot-checking).
"""

import argparse
import json
import pickle
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from sklearn.decomposition import PCA
from sklearn.ensemble import HistGradientBoostingClassifier

import os

ROOT = Path(__file__).resolve().parent.parent
DATA = Path(os.environ.get("GOALIE_ML_DATA") or ROOT / "data")  # override for tests
FEAT = DATA / "features"
EVAL = DATA / "eval"
MODELS = Path(os.environ.get("GOALIE_ML_MODELS") or ROOT / "models")

STEP = 0.5                 # seconds per row (embedding rate)
POS_WITHIN = 0.75          # row is a shot if a tagged shot is this close
IGNORE_WITHIN = 1.75       # rows between POS_WITHIN and this are left out of training
MATCH_TOL = 2.0            # a found shot counts if within this of a tagged one
MIN_GAP = 2.5              # two found shots must be at least this far apart
PCA_DIMS = 24
NEG_KEEP = 0.35            # share of plain "no shot" rows kept for training
RAW_OFFSETS = [-2, -1, 0, 1, 2]                  # rows (x0.5 s) with full features
MOTION_SERIES = (-24, 16)                        # motion frames (x0.25 s): -6 s .. +4 s


# ---------------------------------------------------------------- loading

def load_segments():
    """One dict per extracted segment with its arrays."""
    segs = []
    for meta_path in sorted(FEAT.glob("*.json")):
        m = json.loads(meta_path.read_text())
        prefix = str(meta_path)[:-5]
        motion = np.fromfile(prefix + ".motion.f32", dtype=np.float32)
        emb = np.fromfile(prefix + ".emb.f16", dtype=np.float16)
        md, d = m["motion_dims"], m["dim"]
        if d == 0 or emb.size == 0:
            continue
        motion = motion[: (motion.size // md) * md].reshape(-1, md)
        emb = emb[: (emb.size // d) * d].reshape(-1, d).astype(np.float32)
        m.update(motion=motion, emb=emb)
        segs.append(m)
    return segs


def film_index():
    films = {}
    for line in (DATA / "games.jsonl").read_text().splitlines():
        g = json.loads(line)
        for f in g["film"]:
            f = dict(f, game_id=g["game_id"], user_id=g["user_id"], date=g.get("date"), opponent=g.get("opponent"))
            films[str(f["video_id"])] = f
    return films


def tracked_side(film, t):
    """+1 left / -1 right / 0 unknown: the tracked goalie's net at time t."""
    pm = film.get("period_marks") or {}
    first = pm.get("_net")
    if first not in ("left", "right"):
        return 0.0
    p2, p3 = pm.get("2"), pm.get("3")
    period = 1
    if isinstance(p2, (int, float)) and t >= p2:
        period = 2
    if isinstance(p3, (int, float)) and t >= p3:
        period = 3
    side = first if period != 2 else ("right" if first == "left" else "left")
    return 1.0 if side == "left" else -1.0


# ---------------------------------------------------------------- features

def segment_rows(seg, pca, film):
    """Feature matrix + times for one segment, one row per 0.5 s."""
    emb = pca.transform(seg["emb"]).astype(np.float32)          # [n, PCA_DIMS]
    mo = seg["motion"]                                           # [frames, 65]
    per = int(seg["emb_every"])                                  # motion frames per row
    n = min(len(emb), len(mo) // per)
    if n < 10:
        return None, None
    emb = emb[:n]
    mo = mo[: n * per]
    mo_rows = mo.reshape(n, per, -1)
    change = mo_rows[:, :, :32]
    base = np.concatenate([
        emb,
        change.mean(1), change.max(1),                          # where things move
        mo_rows[:, :, 32:64].mean(1),                           # where the camera points
        mo_rows[:, :, 64:65].mean(1),
    ], axis=1)                                                   # [n, B]

    def shifted(a, k):
        out = np.empty_like(a)
        if k > 0:
            out[:-k] = a[k:]; out[-k:] = a[-1]
        elif k < 0:
            out[-k:] = a[:k]; out[:-k] = a[0]
        else:
            out[:] = a
        return out

    parts = [shifted(base, k) for k in RAW_OFFSETS]
    parts.append(shifted(emb, 2) - shifted(emb, -2))             # scene change across +/-1 s

    overall = mo[:, 64]
    lo, hi = MOTION_SERIES
    idx = np.arange(n)[:, None] * per + np.arange(lo, hi)[None, :]
    idx = np.clip(idx, 0, len(overall) - 1)
    series = overall[idx]                                        # [n, 40]
    parts.append(series)
    parts.append(np.stack([series.mean(1), series.max(1), series.std(1)], 1))

    times = seg["start"] + np.arange(n) * STEP
    side = np.array([tracked_side(film, t) for t in times], dtype=np.float32)[:, None]
    parts.append(side)
    return np.concatenate(parts, axis=1).astype(np.float32), times


def labels_for(times, shot_times):
    st = np.asarray(sorted(shot_times), dtype=np.float64)
    if st.size == 0:
        return np.zeros(len(times), np.int8), np.full(len(times), np.inf)
    pos = np.searchsorted(st, times)
    left = np.abs(times - st[np.clip(pos - 1, 0, st.size - 1)])
    right = np.abs(st[np.clip(pos, 0, st.size - 1)] - times)
    dist = np.minimum(left, right)
    return (dist <= POS_WITHIN).astype(np.int8), dist


# ---------------------------------------------------------------- events

def pick_peaks(times, scores, threshold):
    """Local maxima above threshold, at least MIN_GAP apart (best first)."""
    s = np.convolve(scores, np.ones(3) / 3, mode="same")
    cand = np.where((s >= threshold) & (s >= np.roll(s, 1)) & (s >= np.roll(s, -1)))[0]
    cand = cand[np.argsort(-s[cand])]
    taken = []
    for i in cand:
        if all(abs(times[i] - times[j]) >= MIN_GAP for j in taken):
            taken.append(i)
    taken.sort()
    return times[taken], s[taken]


def match(pred_t, true_t):
    """Greedy one-to-one matching within MATCH_TOL. Returns (tp, offsets, matched_pred, matched_true)."""
    true_t = np.asarray(sorted(true_t))
    used = np.zeros(len(true_t), bool)
    mp, offsets = [], []
    for k, t in enumerate(pred_t):
        if not len(true_t):
            break
        d = np.abs(true_t - t)
        d[used] = np.inf
        j = int(np.argmin(d))
        if d[j] <= MATCH_TOL:
            used[j] = True
            mp.append(k)
            offsets.append(t - true_t[j])
    return len(mp), offsets, set(mp), used


def evaluate(per_film, thresholds):
    """per_film: list of (times, scores, true_times_in_span, minutes). Sweeps thresholds."""
    rows = []
    for th in thresholds:
        tp = fp = fn = 0
        for times, scores, true_t, _ in per_film:
            pt, _ = pick_peaks(times, scores, th)
            k, _, _, _ = match(pt, true_t)
            tp += k; fp += len(pt) - k; fn += len(true_t) - k
        prec = tp / max(tp + fp, 1)
        rec = tp / max(tp + fn, 1)
        f1 = 2 * prec * rec / max(prec + rec, 1e-9)
        rows.append(dict(threshold=float(th), tp=tp, fp=fp, fn=fn, precision=prec, recall=rec, f1=f1))
    return rows


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--folds", type=int, default=5)
    ap.add_argument("--quick", action="store_true", help="fewer boosting rounds (smoke test)")
    args = ap.parse_args()

    films = film_index()
    segs = [s for s in load_segments() if str(s["video_id"]) in films]
    if not segs:
        sys.exit("No features yet. Run: node --env-file=.env ml/detect/extract-features.mjs")
    print(f"{len(segs)} segments from {len({s['video_id'] for s in segs})} films")

    # PCA on embeddings (unsupervised, no labels involved).
    sample = np.concatenate([s["emb"][:: max(1, len(s["emb"]) // 4000)] for s in segs])
    pca = PCA(n_components=min(PCA_DIMS, sample.shape[1]), random_state=0).fit(sample)
    print(f"PCA keeps {pca.explained_variance_ratio_.sum():.0%} of embedding variance")

    # Rows per film.
    by_film = {}
    for s in segs:
        f = films[str(s["video_id"])]
        X, t = segment_rows(s, pca, f)
        if X is None:
            continue
        y, dist = labels_for(t, f["shot_times"])
        by_film.setdefault(str(s["video_id"]), []).append((X, t, y, dist))
    film_ids = sorted(by_film)
    goalie_of = {v: str(films[v]["user_id"]) for v in film_ids}
    goalies = sorted(set(goalie_of.values()))
    total_rows = sum(len(x[1]) for v in film_ids for x in by_film[v])
    print(f"{len(film_ids)} films, {len(goalies)} goalies, {total_rows} half-second rows "
          f"({total_rows * STEP / 3600:.1f} h), feature width {by_film[film_ids[0]][0][0].shape[1]}")

    rng = np.random.default_rng(0)

    def train_set(vids):
        Xs, ys = [], []
        for v in vids:
            for X, t, y, dist in by_film[v]:
                keep = (y == 1) | ((dist > IGNORE_WITHIN) & (rng.random(len(y)) < NEG_KEEP))
                Xs.append(X[keep]); ys.append(y[keep])
        X = np.concatenate(Xs); y = np.concatenate(ys)
        w = np.where(y == 1, (y == 0).sum() / max((y == 1).sum(), 1), 1.0)
        return X, y, w

    def make_model():
        return HistGradientBoostingClassifier(
            max_iter=60 if args.quick else 400, learning_rate=0.06, max_leaf_nodes=31,
            min_samples_leaf=40, l2_regularization=1.0, max_features=0.5,
            early_stopping=False, random_state=0)

    def film_eval_inputs(v, model):
        out = []
        for X, t, y, dist in by_film[v]:
            scores = model.predict_proba(X)[:, 1]
            lo, hi = t[0], t[-1]
            true_t = [s for s in films[v]["shot_times"] if lo <= s <= hi]
            out.append((t, scores, true_t, (hi - lo) / 60))
        return out

    # ---- cross-validation: whole goalies held out ----
    folds = min(args.folds, len(goalies))
    order = rng.permutation(goalies)
    # Balance folds by number of films.
    fold_of_goalie, load = {}, [0] * folds
    for gl in sorted(order, key=lambda g: -sum(goalie_of[v] == g for v in film_ids)):
        k = int(np.argmin(load)); fold_of_goalie[gl] = k
        load[k] += sum(goalie_of[v] == gl for v in film_ids)

    oof = {}  # film -> list of (t, scores, true_t, minutes)
    for k in range(folds):
        test = [v for v in film_ids if fold_of_goalie[goalie_of[v]] == k]
        train = [v for v in film_ids if fold_of_goalie[goalie_of[v]] != k]
        if not test or not train:
            continue
        X, y, w = train_set(train)
        model = make_model().fit(X, y, sample_weight=w)
        for v in test:
            oof[v] = film_eval_inputs(v, model)
        print(f"fold {k + 1}/{folds}: trained on {len(train)} films ({int(y.sum())} shot rows), scored {len(test)}")

    per_film = [x for v in film_ids if v in oof for x in oof[v]]
    thresholds = np.round(np.arange(0.05, 0.96, 0.025), 3)
    sweep = evaluate(per_film, thresholds)
    best = max(sweep, key=lambda r: r["f1"])
    high_recall = [r for r in sweep if r["recall"] >= 0.95]
    review = max(high_recall, key=lambda r: r["threshold"]) if high_recall else max(sweep, key=lambda r: r["recall"])
    minutes = sum(x[3] for x in per_film)

    # ---- per-film detail at the review threshold ----
    EVAL.mkdir(parents=True, exist_ok=True)
    film_lines, all_offsets = [], []
    for v in film_ids:
        if v not in oof:
            continue
        tp = fp = fn = 0
        rows = []
        for t, scores, true_t, _ in oof[v]:
            pt, ps = pick_peaks(t, scores, review["threshold"])
            k, offs, mp, used = match(pt, true_t)
            all_offsets += offs
            tp += k; fp += len(pt) - k; fn += len(true_t) - k
            for i, (a, b) in enumerate(zip(pt, ps)):
                rows.append((a, "found" if i in mp else "extra", b))
            for j, s in enumerate(sorted(true_t)):
                if not used[j]:
                    rows.append((s, "missed", ""))
        rows.sort()
        with open(EVAL / f"film_{v}.csv", "w") as fh:
            fh.write("t_seconds,mm:ss,result,score\n")
            for a, r, b in rows:
                fh.write(f"{a:.1f},{int(a // 60)}:{int(a % 60):02d},{r},{'' if b == '' else f'{b:.3f}'}\n")
        f = films[v]
        film_lines.append(f"| {f.get('date') or '?'} | {f.get('opponent') or '?'} | {v} | {tp + fn} | {tp} | {fn} | {fp} |")

    # ---- final model on everything ----
    X, y, w = train_set(film_ids)
    final = make_model().fit(X, y, sample_weight=w)
    MODELS.mkdir(parents=True, exist_ok=True)
    config = dict(step=STEP, pos_within=POS_WITHIN, min_gap=MIN_GAP, match_tol=MATCH_TOL,
                  raw_offsets=RAW_OFFSETS, motion_series=MOTION_SERIES, pca_dims=PCA_DIMS,
                  threshold_best_f1=best["threshold"], threshold_review=review["threshold"],
                  trained_on_films=film_ids, trained_at=datetime.now(timezone.utc).isoformat())
    with open(MODELS / "shot_detector.pkl", "wb") as fh:
        pickle.dump(dict(model=final, pca=pca, config=config), fh)

    # ---- report ----
    offs = np.abs(np.array(all_offsets)) if all_offsets else np.array([np.nan])
    hours = minutes / 60
    lines = [
        "# Shot detection — cross-validated results",
        "",
        f"Trained {config['trained_at'][:16].replace('T', ' ')} UTC on {len(film_ids)} films "
        f"({len(goalies)} goalies, {hours:.1f} h of live film, "
        f"{sum(len(x[2]) for x in per_film)} tagged shots).",
        "",
        f"Every number below comes from a model that never saw that goalie's games "
        f"({folds}-fold, whole goalies held out). A found shot counts if it is within "
        f"±{MATCH_TOL:.0f} s of a tagged one.",
        "",
        "## Two operating points",
        "",
        "| Setting | Threshold | Shots found (recall) | Correct when it says shot (precision) | Extra moments per game hour | Missed shots |",
        "|---|---|---|---|---|---|",
        f"| **Review mode** (find ≥95% if possible) | {review['threshold']:.3f} | {review['recall']:.1%} | {review['precision']:.1%} | {review['fp'] / hours:.1f} | {review['fn']} |",
        f"| Best balance (F1 {best['f1']:.2f}) | {best['threshold']:.3f} | {best['recall']:.1%} | {best['precision']:.1%} | {best['fp'] / hours:.1f} | {best['fn']} |",
        "",
        f"Timing of found shots (review mode): median {np.median(offs):.2f} s off, 90% within {np.percentile(offs, 90):.2f} s.",
        "",
        "Review mode is the intended use: the model proposes moments, the admin confirms, "
        "drops extras and tags. Missed shots still have to be added by hand.",
        "",
        "## Per film (review mode)",
        "",
        "Details per film in `film_<video>.csv` (found / missed / extra, with timestamps).",
        "",
        "| Date | Opponent | Video | Tagged | Found | Missed | Extra |",
        "|---|---|---|---|---|---|---|",
        *film_lines,
        "",
        "## Threshold sweep",
        "",
        "| Threshold | Recall | Precision | F1 | Extra per hour |",
        "|---|---|---|---|---|",
        *[f"| {r['threshold']:.3f} | {r['recall']:.1%} | {r['precision']:.1%} | {r['f1']:.2f} | {r['fp'] / hours:.1f} |" for r in sweep[::2]],
        "",
    ]
    (EVAL / "report.md").write_text("\n".join(lines))
    (EVAL / "sweep.json").write_text(json.dumps(sweep, indent=1))
    print("\n".join(lines[:16]))
    print(f"\nSaved {MODELS / 'shot_detector.pkl'} and {EVAL / 'report.md'}")


if __name__ == "__main__":
    main()
