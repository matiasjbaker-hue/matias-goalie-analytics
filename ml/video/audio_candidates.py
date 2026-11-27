"""Round-4 cross-validated candidates, labelled, for the audio test.

Writes ml/data/audio/candidates.json: per film, every peak the round-4 model
picks at threshold 0.02 (its most inclusive setting), whether it matches a
tagged shot (±2 s), its model score, plus the shots and hours in the span scored.
"""
import json
import sys
from pathlib import Path

import numpy as np
import modal

sys.path.insert(0, str(Path(__file__).resolve().parent))
import shots_modal as S  # noqa: E402
import launch as L  # noqa: E402

films = L.load_films(True)
done = modal.Function.from_name("goalieiq-shots", "load_scores").remote()
res = {}
for lab, r in done.items():
    if lab.startswith("r4net100%/"):
        res.update(r)
fold_of, _ = S.goalie_folds(films, 5)
out = {}
for v, segs in res.items():
    cands, n_true, hours = [], 0, 0.0
    for t, s, a, b in segs:
        t, s = np.array(t), np.array(s)
        true = sorted(x for x in films[v]["shot_times"] if t[0] - 1 <= x <= t[-1] + 1)
        pt, ps = S.pick_peaks(t, s, 0.02)
        _, _, mp, _ = S.match(pt, true)
        cands += [dict(t=float(p), score=float(sc), shot=int(i in mp)) for i, (p, sc) in enumerate(zip(pt, ps))]
        n_true += len(true)
        hours += (t[-1] - t[0] + S.STRIDE) / 3600
    out[v] = dict(video_id=v, storage_path=films[v]["storage_path"], user_id=films[v]["user_id"],
                  fold=fold_of.get(v), n_true=n_true, hours=hours, cands=cands)
path = S.REPO / "ml" / "data" / "audio" / "candidates.json"
path.write_text(json.dumps(out))
n = sum(len(f["cands"]) for f in out.values())
print(f"{len(out)} films, {n} candidates, {sum(c['shot'] for f in out.values() for c in f['cands'])} match a tag, "
      f"{sum(f['n_true'] for f in out.values())} tagged shots, {sum(f['hours'] for f in out.values()):.1f} h -> {path}")
