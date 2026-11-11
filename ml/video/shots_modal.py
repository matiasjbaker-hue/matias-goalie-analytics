"""
ROUND 2 — shot detection with a fine-tuned video model, on Modal GPUs
======================================================================

    ml/.venv/bin/modal run ml/video/shots_modal.py --step smoke     # ~cents: 3 films, 1 short fold
    ml/.venv/bin/modal run ml/video/shots_modal.py --step prepare   # cut clips for all films (CPU)
    ml/.venv/bin/modal run ml/video/shots_modal.py --step train     # 5 folds x 3 data sizes (GPU)
    ml/.venv/bin/modal run ml/video/shots_modal.py --step all       # prepare + train
    ml/.venv/bin/modal run ml/video/shots_modal.py --step report    # rebuild report from saved scores

Needs (one-time): `modal setup`, and a Modal secret named `goalieiq-r2`
with the four R2_* variables (`modal secret create goalieiq-r2 --from-dotenv .env`).
Reads ml/data/games.jsonl (built by ml/export-dataset.mjs).

What happens
1. prepare (CPU, one container per film, in parallel): ffmpeg streams the
   film from R2 (tagged span of live play, cuts removed) into a small
   8 fps 228x128 copy on the `goalieiq-ml` volume, then cuts 4 s windows:
   one per tagged shot, plus 4 "no shot" windows per shot (half of them
   2.5-8 s from a shot: same play, no shot).
2. train (GPU, one container per fold): fine-tunes torchvision's
   r2plus1d_18 (pretrained on Kinetics-400) on 2 s / 16-frame clips:
   shot vs no shot, plus the tracked net side when the film has it.
   Then scores every half-second of the held-out goalies' films.
3. evaluate (here): same peak picking and +/- 2 s matching as round 1
   (ml/detect/train.py), whole goalies held out, so numbers compare.
   The data-amount test retrains each fold on 25% / 50% / 100% of its
   training games to show whether more tagged games would still help.

Writes ml/data/eval_video/report.md (+ sweep and per-film CSVs).
"""

import json
import os
import subprocess
from pathlib import Path

import numpy as np
import modal

# ---------------------------------------------------------------- settings

FPS = 8
W, H = 228, 128
CLIP_FRAMES = 32          # stored window: anchor-2 s .. anchor+2 s
IN_FRAMES = 16            # model input: 2 s
IN_START = 6              # crop start in a stored window -> anchor-1.25 s .. anchor+0.75 s
JITTER = 4                # +/- frames of temporal jitter in training (0.5 s)
LEAD = (CLIP_FRAMES // 2 - IN_START) / FPS   # 1.25 s of context before the scored moment
STRIDE = 0.5              # scoring step (s)
NEG_PER_POS = 4
HARD_LO, HARD_HI = 2.5, 8.0
BEFORE_FIRST, AFTER_LAST, MIN_SEGMENT = 120, 60, 10
MATCH_TOL, MIN_GAP = 2.0, 2.5
MEAN = np.array([0.43216, 0.394666, 0.37645], np.float32)
STD = np.array([0.22803, 0.22145, 0.216989], np.float32)

# Repo root on the Mac (the cloud copy lives at /root/shots_modal.py, where this is unused).
_here = Path(__file__).resolve()
REPO = _here.parents[2] if len(_here.parents) > 2 else _here.parent


# ---------------------------------------------------------------- film helpers

def live_segments(film, all_live=False):
    """[start, end] seconds of live play (cuts removed), trimmed to the tagged span."""
    dur = film.get("duration_seconds")
    if not dur:
        return []
    cuts = sorted(
        (max(0.0, float(a)), min(dur, float(b)))
        for a, b in (film.get("period_marks") or {}).get("_cuts") or []
        if float(b) > float(a)
    )
    segs, at = [], 0.0
    for a, b in cuts:
        if a > at:
            segs.append([at, a])
        at = max(at, b)
    if at < dur:
        segs.append([at, dur])
    shots = film.get("shot_times") or []
    if not all_live and shots:
        lo, hi = max(0.0, shots[0] - BEFORE_FIRST), min(dur, shots[-1] + AFTER_LAST)
        segs = [[max(a, lo), min(b, hi)] for a, b in segs if min(b, hi) > max(a, lo)]
    return [[round(a, 2), round(b, 2)] for a, b in segs if b - a >= MIN_SEGMENT]


def tracked_side(film, t):
    """+1 left / -1 right / 0 unknown: the tracked goalie's net at time t."""
    pm = film.get("period_marks") or {}
    first = pm.get("_net")
    if first not in ("left", "right"):
        return 0.0
    period = 1
    if isinstance(pm.get("2"), (int, float)) and t >= pm["2"]:
        period = 2
    if isinstance(pm.get("3"), (int, float)) and t >= pm["3"]:
        period = 3
    side = first if period != 2 else ("right" if first == "left" else "left")
    return 1.0 if side == "left" else -1.0


def nearest_dist(times, shots):
    st = np.asarray(sorted(shots), np.float64)
    times = np.asarray(times, np.float64)
    if st.size == 0:
        return np.full(times.shape, np.inf)
    i = np.searchsorted(st, times)
    left = np.abs(times - st[np.clip(i - 1, 0, st.size - 1)])
    right = np.abs(st[np.clip(i, 0, st.size - 1)] - times)
    return np.minimum(left, right)


def ffmpeg_small_copy(src, start, dur, out):
    out.parent.mkdir(parents=True, exist_ok=True)
    net = ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "10"] if str(src).startswith("http") else []
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *net,
        "-ss", str(start), "-i", str(src), "-t", str(dur),
        "-an", "-vf", f"fps={FPS},scale={W}:{H}", "-c:v", "libx264", "-preset", "veryfast",
        "-crf", "23", "-g", str(2 * FPS), str(out),
    ], check=True)


def decode(path):
    raw = subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(path), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        check=True, capture_output=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(-1, H, W, 3)


def build_windows(frames, seg_start, shots, film, rng):
    """Shot windows + sampled no-shot windows for one segment."""
    n = len(frames)
    seg_end = seg_start + n / FPS
    half = CLIP_FRAMES // 2

    def index(a):
        i = int(round((a - seg_start) * FPS))
        return i if i - half >= 0 and i + half <= n else None

    pos = [s for s in shots if index(s) is not None]
    cand = np.arange(seg_start + 2.0, seg_end - 2.0, 0.25)
    d = nearest_dist(cand, shots)
    hard, easy = cand[(d >= HARD_LO) & (d <= HARD_HI)], cand[d > HARD_HI]
    n_neg = NEG_PER_POS * len(pos) + int((seg_end - seg_start) / 120)
    n_hard = min(len(hard), n_neg // 2)
    negs = list(rng.choice(hard, n_hard, replace=False)) if n_hard else []
    n_easy = min(len(easy), n_neg - n_hard)
    negs += list(rng.choice(easy, n_easy, replace=False)) if n_easy else []
    anchors = [a for a in pos + negs if index(a) is not None]
    labels = [1] * len(pos) + [0] * (len(anchors) - len(pos))
    if not anchors:
        return None
    clips = np.stack([frames[index(a) - half: index(a) + half] for a in anchors])
    sides = [tracked_side(film, a) for a in anchors]
    return clips, labels, [float(a) for a in anchors], sides


def goalie_folds(films, k, seed=0):
    """film id -> fold, whole goalies per fold, balanced by film count (as round 1)."""
    ids = sorted(films)
    goalie_of = {v: str(films[v]["user_id"]) for v in ids}
    goalies = sorted(set(goalie_of.values()))
    k = min(k, len(goalies))
    order = np.random.default_rng(seed).permutation(goalies)
    count = {g: sum(goalie_of[v] == g for v in ids) for g in goalies}
    fold_of, load = {}, [0] * k
    for g in sorted(order, key=lambda g: -count[g]):
        f = int(np.argmin(load))
        fold_of[g] = f
        load[f] += count[g]
    return {v: fold_of[goalie_of[v]] for v in ids}, k


# ---------------------------------------------------------------- events + metrics (as round 1)

def pick_peaks(times, scores, threshold):
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
    true_t = np.asarray(sorted(true_t))
    used = np.zeros(len(true_t), bool)
    mp, offsets = set(), []
    for k, t in enumerate(pred_t):
        if not len(true_t):
            break
        d = np.abs(true_t - t)
        d[used] = np.inf
        j = int(np.argmin(d))
        if d[j] <= MATCH_TOL:
            used[j] = True
            mp.add(k)
            offsets.append(t - true_t[j])
    return len(mp), offsets, mp, used


def sweep(per_film, thresholds):
    rows = []
    for th in thresholds:
        tp = fp = fn = 0
        for times, scores, true_t in per_film:
            pt, _ = pick_peaks(times, scores, th)
            k, _, _, _ = match(pt, true_t)
            tp += k; fp += len(pt) - k; fn += len(true_t) - k
        p, r = tp / max(tp + fp, 1), tp / max(tp + fn, 1)
        rows.append(dict(threshold=float(th), tp=tp, fp=fp, fn=fn, precision=p, recall=r,
                         f1=2 * p * r / max(p + r, 1e-9)))
    return rows


def headline(rows, hours):
    best = max(rows, key=lambda r: r["f1"])
    ok60 = [r for r in rows if r["fp"] / hours <= 60]
    at60 = max(ok60, key=lambda r: r["recall"]) if ok60 else None
    r90 = [r for r in rows if r["recall"] >= 0.90]
    at90 = max(r90, key=lambda r: r["threshold"]) if r90 else None
    r95 = [r for r in rows if r["recall"] >= 0.95]
    review = max(r95, key=lambda r: r["threshold"]) if r95 else max(rows, key=lambda r: r["recall"])
    return best, at60, at90, review


# ---------------------------------------------------------------- model

def make_model(pretrained=True):
    import torch
    import torch.nn as nn
    from torchvision.models.video import r2plus1d_18, R2Plus1D_18_Weights

    class ShotNet(nn.Module):
        def __init__(self):
            super().__init__()
            m = r2plus1d_18(weights=R2Plus1D_18_Weights.KINETICS400_V1 if pretrained else None)
            m.fc = nn.Identity()
            self.backbone = m
            self.side = nn.Linear(1, 16)
            self.head = nn.Sequential(nn.Dropout(0.3), nn.Linear(512 + 16, 1))

        def forward(self, x, side):
            f = self.backbone(x)
            s = torch.relu(self.side(side[:, None]))
            return self.head(torch.cat([f, s], 1)).squeeze(1)

    return ShotNet()


def to_input(batch_u8, device):
    """[B,T,H,W,3] uint8 -> normalized [B,3,T,H,W] float."""
    import torch
    x = batch_u8.to(device, non_blocking=True).float().div_(255)
    x = (x - torch.tensor(MEAN, device=device)) / torch.tensor(STD, device=device)
    return x.permute(0, 4, 1, 2, 3).contiguous()


# ---------------------------------------------------------------- core steps (local or Modal)

def prepare_core(film, src, root):
    """Small film copy + training windows for one film. Idempotent."""
    vid = str(film["video_id"])
    meta_path = root / "windows" / f"{vid}.json"
    if meta_path.exists():
        return json.loads(meta_path.read_text())
    (root / "windows").mkdir(parents=True, exist_ok=True)
    shots = sorted(film.get("shot_times") or [])
    rng = np.random.default_rng(int(vid))
    clips, labels, anchors, sides, segs = [], [], [], [], []
    for n, (a, b) in enumerate(live_segments(film)):
        mp4 = root / "film" / f"{vid}_{n}.mp4"
        if not mp4.exists():
            ffmpeg_small_copy(src, a, b - a, mp4.with_suffix(".part.mp4"))
            mp4.with_suffix(".part.mp4").rename(mp4)
        frames = decode(mp4)
        segs.append(dict(n=n, start=a, end=b, frames=int(len(frames)), path=f"film/{vid}_{n}.mp4"))
        got = build_windows(frames, a, shots, film, rng)
        if got:
            clips.append(got[0]); labels += got[1]; anchors += got[2]; sides += got[3]
        del frames
    if clips:
        np.save(root / "windows" / f"{vid}_clips.npy", np.concatenate(clips))
    meta = dict(video_id=vid, user_id=str(film["user_id"]), segments=segs, labels=labels,
                anchors=anchors, sides=sides, n_pos=int(sum(labels)), n_neg=int(len(labels) - sum(labels)))
    meta_path.write_text(json.dumps(meta))
    return meta


def train_core(root, train_ids, epochs=8, device="cuda", pretrained=True, max_windows=None, batch_size=16, log=print):
    import torch
    from torch.utils.data import Dataset, DataLoader

    metas = [json.loads((root / "windows" / f"{v}.json").read_text()) for v in train_ids]
    metas = [m for m in metas if m["labels"]]
    index = [(i, r) for i, m in enumerate(metas) for r in range(len(m["labels"]))]
    if max_windows:
        index = [index[j] for j in np.random.default_rng(0).permutation(len(index))[:max_windows]]
    labels = np.array([metas[i]["labels"][r] for i, r in index], np.float32)
    n_pos, n_neg = int(labels.sum()), int(len(labels) - labels.sum())
    log(f"training on {len(metas)} films: {n_pos} shot / {n_neg} no-shot windows")

    class Windows(Dataset):
        def __init__(self):
            self.arrays = {}

        def __len__(self):
            return len(index)

        def __getitem__(self, j):
            i, r = index[j]
            if i not in self.arrays:
                self.arrays[i] = np.load(root / "windows" / f"{metas[i]['video_id']}_clips.npy", mmap_mode="r")
            s = IN_START + np.random.randint(-JITTER, JITTER + 1)
            clip = np.asarray(self.arrays[i][r, s: s + IN_FRAMES])
            side = metas[i]["sides"][r]
            if np.random.rand() < 0.5:
                clip = clip[:, :, ::-1]
                side = -side
            return torch.from_numpy(clip.copy()), torch.tensor(labels[j]), torch.tensor(side, dtype=torch.float32)

    cuda = device == "cuda"
    loader = DataLoader(Windows(), batch_size=batch_size, shuffle=True, num_workers=6 if cuda else 0,
                        pin_memory=cuda, drop_last=len(index) > batch_size, persistent_workers=cuda)
    model = make_model(pretrained).to(device)
    opt = torch.optim.AdamW([
        dict(params=model.backbone.parameters(), lr=1e-4),
        dict(params=list(model.side.parameters()) + list(model.head.parameters()), lr=1e-3),
    ], weight_decay=1e-4)
    steps = max(1, epochs * len(loader))
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=[1e-4, 1e-3], total_steps=steps, pct_start=0.15)
    loss_fn = torch.nn.BCEWithLogitsLoss(pos_weight=torch.tensor(n_neg / max(n_pos, 1), device=device))
    model.train()
    for ep in range(epochs):
        total, seen = 0.0, 0
        for x, y, side in loader:
            x = to_input(x, device)
            x = x * torch.empty(x.shape[0], 1, 1, 1, 1, device=device).uniform_(0.85, 1.15)  # brightness
            y, side = y.to(device), side.to(device)
            with torch.autocast("cuda", dtype=torch.bfloat16, enabled=cuda):
                loss = loss_fn(model(x, side).float(), y)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step()
            sched.step()
            total += loss.item() * len(y); seen += len(y)
        log(f"epoch {ep + 1}/{epochs}: loss {total / max(seen, 1):.4f}")
    model.eval()
    return model


def score_core(model, root, film, device="cuda", batch=64, max_seconds=None):
    """Score every STRIDE seconds of a prepared film. Returns [(times, scores, seg_start, seg_end)]."""
    import torch
    meta = json.loads((root / "windows" / f"{film['video_id']}.json").read_text())
    out = []
    for seg in meta["segments"]:
        frames = decode(root / seg["path"])
        start, n = seg["start"], len(frames)
        times = np.arange(start + LEAD, start + n / FPS - (IN_FRAMES / FPS - LEAD), STRIDE)
        if max_seconds:
            times = times[: int(max_seconds / STRIDE)]
        scores = np.zeros(len(times), np.float32)
        sides = torch.tensor([tracked_side(film, t) for t in times], dtype=torch.float32)
        for b in range(0, len(times), batch):
            idx = [int(round((t - LEAD - start) * FPS)) for t in times[b: b + batch]]
            clip = torch.from_numpy(np.stack([frames[i: i + IN_FRAMES] for i in idx]))
            with torch.no_grad(), torch.autocast("cuda", dtype=torch.bfloat16, enabled=device == "cuda"):
                logits = model(to_input(clip, device), sides[b: b + batch].to(device))
            scores[b: b + len(idx)] = torch.sigmoid(logits.float()).cpu().numpy()
        out.append((times, scores, start, start + n / FPS))
        del frames
    return out


def evaluate_core(results, films, out_dir, title, curve=None):
    """results: {video_id: [(times, scores, seg_start, seg_end)]}. Writes report; returns headline."""
    out_dir.mkdir(parents=True, exist_ok=True)
    per_film, minutes = [], 0.0
    for v, segs in results.items():
        for times, scores, a, b in segs:
            true_t = [s for s in films[v]["shot_times"] if times[0] - 1 <= s <= times[-1] + 1]
            per_film.append((np.asarray(times), np.asarray(scores), true_t))
            minutes += (times[-1] - times[0] + STRIDE) / 60   # span actually scored
    hours = minutes / 60
    rows = sweep(per_film, np.round(np.arange(0.02, 0.99, 0.01), 2))
    best, at60, at90, review = headline(rows, hours)

    film_lines, offsets = [], []
    for v, segs in sorted(results.items()):
        tp = fp = fn = 0
        lines = []
        for times, scores, a, b in segs:
            times, scores = np.asarray(times), np.asarray(scores)
            true_t = sorted(s for s in films[v]["shot_times"] if times[0] - 1 <= s <= times[-1] + 1)
            pt, ps = pick_peaks(times, scores, review["threshold"])
            k, offs, mp, used = match(pt, true_t)
            offsets += offs
            tp += k; fp += len(pt) - k; fn += len(true_t) - k
            lines += [(t, "found" if i in mp else "extra", f"{s:.3f}") for i, (t, s) in enumerate(zip(pt, ps))]
            lines += [(t, "missed", "") for j, t in enumerate(true_t) if not used[j]]
        with open(out_dir / f"film_{v}.csv", "w") as fh:
            fh.write("t_seconds,mm:ss,result,score\n")
            for t, r, s in sorted(lines):
                fh.write(f"{t:.1f},{int(t // 60)}:{int(t % 60):02d},{r},{s}\n")
        f = films[v]
        film_lines.append(f"| {f.get('date') or '?'} | {f.get('opponent') or '?'} | {v} | {tp + fn} | {tp} | {fn} | {fp} |")

    offs = np.abs(np.array(offsets)) if offsets else np.array([np.nan])
    fmt = lambda r: "—" if r is None else f"{r['recall']:.1%} found, {r['precision']:.1%} precise, {r['fp'] / hours:.0f} extra/h (threshold {r['threshold']:.2f})"
    lines = [
        f"# {title}",
        "",
        f"{len(results)} films, {hours:.1f} h of live film, {sum(len(x[2]) for x in per_film)} tagged shots. "
        f"Whole goalies held out; a found shot counts within ±{MATCH_TOL:.0f} s.",
        "",
        "| Operating point | Result |",
        "|---|---|",
        f"| **Review mode** (≥95% found, or the most it can) | {fmt(review)} |",
        f"| ≥90% found | {fmt(at90)} |",
        f"| At most 60 extra moments per game hour (~1/min) | {fmt(at60)} |",
        f"| Best balance (F1 {best['f1']:.2f}) | {fmt(best)} |",
        "",
        "Round 1 for comparison (frame features): 62% found at 330 extra/h; best F1 0.13.",
        "",
        f"Timing of found shots (review mode): median {np.median(offs):.2f} s off, 90% within {np.percentile(offs, 90):.2f} s.",
        "",
    ]
    if curve:
        lines += ["## How much data helps (same held-out goalies, less training data)", "",
                  "| Training games used | Best F1 | Found at ≤60 extra/h | Extra/h at ≥90% found |", "|---|---|---|---|"]
        for label, (b, a60, a90) in curve:
            found60 = "—" if a60 is None else f"{a60['recall']:.1%}"
            extra90 = "—" if a90 is None else f"{a90['fp'] / hours:.0f}"
            lines.append(f"| {label} | {b['f1']:.2f} | {found60} | {extra90} |")
        lines += ["", "Still climbing at 100% → more tagged games will help. Flat → change the model, not the amount of data.", ""]
    lines += ["## Per film (review mode)", "", "| Date | Opponent | Video | Tagged | Found | Missed | Extra |",
              "|---|---|---|---|---|---|---|", *film_lines, "",
              "## Threshold sweep", "", "| Threshold | Found | Precise | F1 | Extra/h |", "|---|---|---|---|---|",
              *[f"| {r['threshold']:.2f} | {r['recall']:.1%} | {r['precision']:.1%} | {r['f1']:.2f} | {r['fp'] / hours:.0f} |" for r in rows[::4]], ""]
    (out_dir / "report.md").write_text("\n".join(lines))
    (out_dir / "sweep.json").write_text(json.dumps(rows, indent=1))
    return (best, at60, at90), "\n".join(lines[:16])


# ---------------------------------------------------------------- Modal wiring

app = modal.App("goalieiq-shots")
image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("ffmpeg")
    .pip_install("torch", "torchvision", "numpy", "boto3")
    .run_commands("python -c \"from torchvision.models.video import r2plus1d_18, R2Plus1D_18_Weights as W; "
                  "r2plus1d_18(weights=W.KINETICS400_V1)\"")
)
volume = modal.Volume.from_name("goalieiq-ml", create_if_missing=True)
DATA = Path("/data")


def r2_url(key):
    import boto3
    from botocore.config import Config
    s3 = boto3.client(
        "s3", endpoint_url=f"https://{os.environ['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"], aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
        region_name="auto", config=Config(signature_version="s3v4"))
    return s3.generate_presigned_url("get_object", Params={"Bucket": os.environ["R2_BUCKET_NAME"], "Key": key},
                                     ExpiresIn=6 * 3600)


@app.function(image=image, volumes={"/data": volume}, secrets=[modal.Secret.from_name("goalieiq-r2")],
              cpu=4.0, memory=16384, timeout=3 * 3600, retries=1)
def prepare_film(film):
    volume.reload()
    meta = prepare_core(film, r2_url(film["storage_path"]), DATA)
    volume.commit()
    return {k: meta[k] for k in ("video_id", "n_pos", "n_neg")} | {"segments": len(meta["segments"])}


@app.function(image=image, gpu="A10G", volumes={"/data": volume}, cpu=8.0, memory=32768, timeout=3 * 3600)
def train_and_score(label, train_ids, test_films, epochs, max_seconds=None):
    import torch
    volume.reload()
    log = lambda m: print(f"[{label}] {m}", flush=True)
    log(f"GPU: {torch.cuda.get_device_name(0)}")
    model = train_core(DATA, train_ids, epochs=epochs, device="cuda", log=log)
    out = {}
    for film in test_films:
        segs = score_core(model, DATA, film, device="cuda", max_seconds=max_seconds)
        out[str(film["video_id"])] = [(t.tolist(), s.tolist(), a, b) for t, s, a, b in segs]
    log(f"scored {len(test_films)} held-out films")
    # Keep the scores on the volume too, so a dropped connection loses nothing
    # (`--step report` rebuilds the report from these).
    (DATA / "scores").mkdir(parents=True, exist_ok=True)
    (DATA / "scores" / f"{label.replace('/', '_')}.json").write_text(json.dumps(out))
    volume.commit()
    return label, out


@app.function(image=image, volumes={"/data": volume}, timeout=600)
def load_scores():
    volume.reload()
    folder = DATA / "scores"
    if not folder.exists():
        return {}
    return {p.stem.replace("_", "/", 1): json.loads(p.read_text()) for p in folder.glob("*.json")}


@app.local_entrypoint()
def main(step: str = "smoke", epochs: int = 8, folds: int = 5, curve: bool = True):
    films = {}
    for line in (REPO / "ml" / "data" / "games.jsonl").read_text().splitlines():
        g = json.loads(line)
        for f in g["film"]:
            films[str(f["video_id"])] = dict(f, video_id=str(f["video_id"]), user_id=str(g["user_id"]),
                                             date=g.get("date"), opponent=g.get("opponent"))
    fold_of, k = goalie_folds(films, folds)
    out_dir = REPO / "ml" / "data" / ("eval_video_smoke" if step == "smoke" else "eval_video")

    if step == "smoke":
        # Three short films from three different goalies; one fold, one epoch, 10 min of scoring.
        by_goalie = {}
        for v in sorted(films, key=lambda v: films[v]["duration_seconds"] or 1e9):
            by_goalie.setdefault(films[v]["user_id"], v)
        pick = list(by_goalie.values())[:3]
        print("smoke test on films", pick)
        for r in prepare_film.map([films[v] for v in pick]):
            print("prepared", r)
        label, res = train_and_score.remote("smoke", pick[:2], [films[pick[2]]], 1, 600)
        res = {v: [(np.array(t), np.array(s), a, b) for t, s, a, b in segs] for v, segs in res.items()}
        _, head = evaluate_core(res, films, out_dir, "Smoke test (not a real result)")
        print(head)
        print(f"Smoke test passed. Report: {out_dir / 'report.md'}")
        return

    if step in ("prepare", "all"):
        total = [0, 0]
        for r in prepare_film.map(list(films.values()), order_outputs=False):
            total[0] += r["n_pos"]; total[1] += r["n_neg"]
            print(f"prepared film {r['video_id']}: {r['n_pos']} shot / {r['n_neg']} no-shot windows")
        print(f"All films prepared: {total[0]} shot / {total[1]} no-shot windows")

    if step in ("train", "all", "report"):
        fractions = [1.0, 0.5, 0.25] if curve else [1.0]
        to_arrays = lambda res: {v: [(np.array(t), np.array(s), a, b) for t, s, a, b in segs] for v, segs in res.items()}
        results = {lab: to_arrays(res) for lab, res in load_scores.remote().items()}
        if results:
            print(f"{len(results)} job(s) already finished earlier: {sorted(results)}")
        jobs = []
        for frac in fractions:
            for f in range(k):
                label = f"{int(frac * 100)}%/fold{f + 1}"
                if label in results:
                    continue
                test = [films[v] for v in films if fold_of[v] == f]
                train = sorted(v for v in films if fold_of[v] != f)
                if frac < 1:
                    n = max(2, int(round(frac * len(train))))
                    train = sorted(np.random.default_rng(100 + f).choice(train, n, replace=False).tolist())
                jobs.append((label, train, test, epochs))
        if step != "report" and jobs:
            print(f"{len(jobs)} GPU jobs to run ({k} folds x {len(fractions)} data sizes)")
            for label, res in train_and_score.starmap(jobs, order_outputs=False):
                results[label] = to_arrays(res)
                print(f"done: {label} ({len(results)}/{k * len(fractions)})")
        elif jobs:
            print(f"Note: {len(jobs)} job(s) not finished yet: {[j[0] for j in jobs]}")
        merged = lambda tag: {v: s for lab, res in results.items() if lab.startswith(tag + "/") for v, s in res.items()}
        heads = []
        for frac in fractions:
            tag = f"{int(frac * 100)}%"
            if not merged(tag):
                continue
            n_films = int(round(frac * len(films) * (k - 1) / k))
            h, _ = evaluate_core(merged(tag), films, out_dir / f"data_{tag[:-1]}pct",
                                 f"Shot detection, video model ({tag} of training games)")
            heads.append((f"{tag} (~{n_films} films)", h))
        if not merged("100%"):
            print("No 100% results yet.")
            return
        _, head = evaluate_core(merged("100%"), films, out_dir, "Shot detection — video model (round 2)",
                                curve=heads if len(heads) > 1 else None)
        print(head)
        print(f"\nReport: {out_dir / 'report.md'}")
