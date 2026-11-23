"""
Round 6: dense shot spotting (the E2E-Spot recipe). See ml/AUDIT.md for why.

Rounds 2-5 classified isolated 2 s clips and slid that classifier over the
game. Here the model reads 8 s of film at 12.5 fps and says, for every frame,
"is a shot on the tracked net happening here?":

    RegNet-Y-200MF (ImageNet) with temporal shifts in every block
    -> bidirectional GRU across the 100 frames -> shot / no shot per frame

Every frame of every training clip is labelled from the tags, so the attacks
without a shot inside a clip become negatives, and the GRU sees the build-up
and the aftermath (rebound, freeze, whistle). Clips are sampled around tagged
shots, around round 4's out-of-fold false alarms, and anywhere.

    ml/.venv/bin/modal deploy ml/video/dense_modal.py           # after code changes
    ml/.venv/bin/python ml/video/dense_modal.py --prepare       # 12.5 fps copies, CPU (~$3-5)
    ml/.venv/bin/python ml/video/dense_modal.py --smoke         # 3 films, a few minutes (~$0.30)
    ml/.venv/bin/python ml/video/dense_modal.py --run d1 --only 1,2,3
    ml/.venv/bin/python ml/video/dense_modal.py --status
    ml/.venv/bin/python ml/video/dense_modal.py --report --run d1   # vs round 4 on the same films

Same films, live segments, goalie folds, matching and report as rounds 2-5
(shots_modal.py), so the numbers compare directly. Separate Modal app, so
the site's model (goalieiq-shots) is untouched.
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import modal

sys.path.insert(0, str(Path(__file__).resolve().parent))
import shots_modal as S  # noqa: E402

FPS = 12.5
COPY_W, COPY_H = 640, 360     # stored copy (lets a later run use more pixels)
IN_W, IN_H = 448, 252         # model input; ffmpeg scales while decoding
CLIP = 100                    # frames per clip: 8 s
POS_RADIUS = 3                # frames either side of a tag labelled "shot" (+/-0.24 s)
POS_WEIGHT = 5.0              # E2E-Spot weights foreground frames 5x
MIX = (0.4, 0.3, 0.3)         # clips around: tagged shots / round-4 false alarms / anywhere
GRID = S.STRIDE               # 0.5 s output grid, as rounds 2-5
LEAD, TAIL = 1.25, 0.75       # rounds 2-5 scored from start+1.25 s to end-0.75 s; same span here
SUB = "dense"
MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)

app = modal.App("goalieiq-dense")
image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("ffmpeg")
    .pip_install("torch", "torchvision", "timm", "numpy", "boto3")
    .run_commands("python -c \"import timm; timm.create_model('regnety_002', pretrained=True)\"")
    .add_local_python_source("shots_modal")
)
volume = modal.Volume.from_name("goalieiq-ml", create_if_missing=True)
ROOT = Path("/data") / SUB


# ---------------------------------------------------------------- video helpers

def make_copy(src, start, dur, out):
    """12.5 fps 640x360 copy of [start, start+dur], a keyframe every 2 s (cheap seeks)."""
    out.parent.mkdir(parents=True, exist_ok=True)
    part = out.with_suffix(".part.mp4")
    net = ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "10"] if str(src).startswith("http") else []
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *net,
        "-ss", str(start), "-i", str(src), "-t", str(dur),
        "-an", "-vf", f"fps={FPS},scale={COPY_W}:{COPY_H}", "-c:v", "libx264", "-preset", "veryfast",
        "-crf", "23", "-g", "25", str(part),
    ], check=True)
    part.rename(out)


def frame_count(path):
    """Video frames in a copy. ffprobe sometimes appends separators ("43019,"), so take the first number."""
    import re
    out = subprocess.run(["ffprobe", "-v", "error", "-count_packets", "-select_streams", "v:0", "-show_entries",
                          "stream=nb_read_packets", "-of", "csv=p=0", str(path)],
                         capture_output=True, text=True, check=True).stdout
    m = re.search(r"\d+", out)
    if not m:
        raise ValueError(f"no frame count for {path}: {out[:80]!r}")
    return int(m.group())


def decode_range(path, first, count, w=IN_W, h=IN_H, threads=1):
    """Frames first..first+count-1 of a copy, scaled to w x h (frame-accurate seek).
    Past the end of the file the last frame repeats, so there are always `count`."""
    t = max(first - 0.49, 0) / FPS
    raw = subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-threads", str(threads), "-ss", f"{t:.4f}",
         "-i", str(path), "-frames:v", str(count), "-vf", f"scale={w}:{h}", "-f", "rawvideo",
         "-pix_fmt", "rgb24", "-"], check=True, capture_output=True).stdout
    a = np.frombuffer(raw, np.uint8).reshape(-1, h, w, 3)
    if len(a) == 0:
        a = np.zeros((1, h, w, 3), np.uint8)
    if len(a) < count:
        a = np.concatenate([a, np.repeat(a[-1:], count - len(a), 0)])
    return a


# ---------------------------------------------------------------- model

def make_dense(pretrained=True):
    import timm
    import torch
    import torch.nn as nn
    from timm.models.regnet import Bottleneck

    class Ctx:
        T = CLIP

    class TemporalShift(nn.Module):
        """TSM: 1/8 of the channels come from the previous frame, 1/8 from the next."""

        def __init__(self, conv, ctx, div=8):
            super().__init__()
            self.conv, self.ctx, self.div = conv, ctx, div

        def forward(self, x):
            nt, c, h, w = x.shape
            t, f = self.ctx.T, c // self.div
            v = x.view(nt // t, t, c, h, w)
            s = v.clone()                       # keeps the channels-last layout
            s[:, 1:, :f] = v[:, :-1, :f]
            s[:, :1, :f] = 0
            s[:, :-1, f:2 * f] = v[:, 1:, f:2 * f]
            s[:, -1:, f:2 * f] = 0
            return self.conv(s.view(nt, c, h, w))

    class DenseSpot(nn.Module):
        def __init__(self):
            super().__init__()
            self.ctx = Ctx()
            self.backbone = timm.create_model("regnety_002", pretrained=pretrained, num_classes=0)
            for m in self.backbone.modules():
                if isinstance(m, Bottleneck):
                    m.conv1 = TemporalShift(m.conv1, self.ctx)
            self.backbone = self.backbone.to(memory_format=torch.channels_last)   # faster convs in bf16
            d = self.backbone.num_features
            self.gru = nn.GRU(d, d, batch_first=True, bidirectional=True)
            self.drop = nn.Dropout(0.2)
            self.fc = nn.Linear(2 * d, 1)

        def forward(self, x):                      # [B, T, 3, H, W], normalized
            b, t = x.shape[:2]
            self.ctx.T = t
            with torch.autocast("cuda", dtype=torch.bfloat16, enabled=x.is_cuda):
                f = self.backbone(x.flatten(0, 1).contiguous(memory_format=torch.channels_last))
            h, _ = self.gru(f.float().view(b, t, -1))   # GRU in fp32
            return self.fc(self.drop(h)).squeeze(-1)    # [B, T] logits

    return DenseSpot()


def to_input(u8, device):
    """[B, T, H, W, 3] uint8 -> [B, T, 3, H, W] normalized float."""
    import torch
    x = u8.to(device, non_blocking=True).float().div_(255)
    x = (x - torch.tensor(MEAN, device=device)) / torch.tensor(STD, device=device)
    return x.permute(0, 1, 4, 2, 3).contiguous()


# ---------------------------------------------------------------- training data

class ClipSampler:
    """Random 8 s training clips. A frame is "shot" within POS_RADIUS frames of a tag.
    Item j of epoch e is always the same clip (seeded), so a restart repeats nothing odd."""

    def __init__(self, films, metas, hard_negs, root, n, seed=0):
        self.items, self.events, self.root, self.n, self.seed, self.epoch = [], {"shot": [], "hard": []}, root, n, seed, 0
        for v, f in films.items():
            for seg in metas[v]["segments"]:
                a, nfr = seg["start"], seg["frames"]
                if nfr < CLIP or S.tracked_side(f, a + nfr / FPS / 2) == 0:
                    continue
                inside = lambda ts: [int(round((t - a) * FPS)) for t in ts if a <= t < a + nfr / FPS]
                i = len(self.items)
                self.items.append(dict(film=f, seg=seg, shots=np.array(inside(f.get("shot_times") or []), int)))
                self.events["shot"] += [(i, x) for x in inside(f.get("shot_times") or [])]
                # Round-4 false alarms, plus missed/blocked shots marked in Review (W / Shift+W):
                # attempts a person confirmed weren't shots on goal.
                attempts = [a.get("t") for a in (f.get("period_marks") or {}).get("_attempts") or []
                            if isinstance(a, dict) and isinstance(a.get("t"), (int, float))]
                self.events["hard"] += [(i, x) for x in inside(list(hard_negs.get(v) or []) + attempts)]
        w = np.array([it["seg"]["frames"] - CLIP + 1 for it in self.items], float)
        self.weights = w / w.sum()

    def __len__(self):
        return self.n

    def pick(self, rng):
        for _ in range(50):
            r = rng.random()
            kind = "shot" if r < MIX[0] else "hard" if r < MIX[0] + MIX[1] else "any"
            if kind != "any" and self.events[kind]:
                i, fr = self.events[kind][int(rng.integers(len(self.events[kind])))]
                first = fr - int(rng.integers(8, CLIP - 8))        # the event lands anywhere but the edges
            else:
                i = int(rng.choice(len(self.items), p=self.weights))
                first = int(rng.integers(0, self.items[i]["seg"]["frames"] - CLIP + 1))
            it = self.items[i]
            first = int(np.clip(first, 0, it["seg"]["frames"] - CLIP))
            side = S.tracked_side(it["film"], it["seg"]["start"] + (first + CLIP / 2) / FPS)
            if side != 0:
                return it, first, side
        raise RuntimeError("could not sample a clip with a known net side")

    def __getitem__(self, j):
        import torch
        rng = np.random.default_rng([self.seed, self.epoch, j])
        it, first, side = self.pick(rng)
        clip = decode_range(self.root / it["seg"]["path"], first, CLIP)
        if side < 0:
            clip = clip[:, :, ::-1]                 # tracked net -> left of the picture
        y = np.zeros(CLIP, np.float32)
        if len(it["shots"]):
            d = np.abs(np.arange(first, first + CLIP)[:, None] - it["shots"][None, :]).min(1)
            y[d <= POS_RADIUS] = 1
        return torch.from_numpy(np.ascontiguousarray(clip)), torch.from_numpy(y)


def train_core(films, metas, hard_negs, root, device="cuda", epochs=15, steps=330, batch=6, lr=1e-3,
               workers=8, log=print, ckpt=None, on_save=None, pretrained=True):
    import torch
    from torch.utils.data import DataLoader
    data = ClipSampler(films, metas, hard_negs, root, steps * batch)
    log(f"training on {len(films)} films: {len(data.events['shot'])} shots, "
        f"{len(data.events['hard'])} round-4 false alarms, {len(data.items)} segments")
    if device == "cuda":
        torch.backends.cudnn.benchmark = True
    model = make_dense(pretrained).to(device)
    opt = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=1e-4)
    total, warm = epochs * steps, min(3 * steps, epochs * steps // 4 + 1)
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda k: (k + 1) / warm if k < warm else 0.5 * (1 + np.cos(np.pi * (k - warm) / max(total - warm, 1))))
    loss_fn = torch.nn.BCEWithLogitsLoss(pos_weight=torch.tensor(POS_WEIGHT, device=device))
    first = 0
    if ckpt is not None and Path(ckpt).exists():
        state = torch.load(ckpt, map_location=device, weights_only=False)
        model.load_state_dict(state["model"]); opt.load_state_dict(state["opt"]); sched.load_state_dict(state["sched"])
        first = state["epoch"]
        log(f"resuming after epoch {first}/{epochs}")
    model.train()
    for ep in range(first, epochs):
        data.epoch = ep
        loader = DataLoader(data, batch_size=batch, shuffle=False, num_workers=workers,
                            pin_memory=device == "cuda", drop_last=True)
        t0, tot, n, wait = time.time(), 0.0, 0, 0.0
        tw = time.time()
        for x, y in loader:
            wait += time.time() - tw
            x = to_input(x, device)
            g = torch.empty(x.shape[0], 1, 1, 1, 1, device=device)
            x = x * g.uniform_(0.8, 1.2) + torch.empty_like(g).uniform_(-0.15, 0.15)   # contrast / brightness
            loss = loss_fn(model(x), y.to(device))
            opt.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
            opt.step()
            sched.step()
            tot += loss.item(); n += 1
            tw = time.time()
        log(f"epoch {ep + 1}/{epochs}: loss {tot / max(n, 1):.4f} ({time.time() - t0:.0f}s, "
            f"{wait:.0f}s waiting for clips)")
        if ckpt is not None:
            tmp = Path(str(ckpt) + ".tmp")
            torch.save(dict(model=model.state_dict(), opt=opt.state_dict(), sched=sched.state_dict(), epoch=ep + 1), tmp)
            tmp.replace(ckpt)
            if on_save:
                on_save()
    model.eval()
    return model


# ---------------------------------------------------------------- scoring

def score_film(model, film, meta, root, device="cuda", batch=16, chunk=2000, max_seconds=None):
    """Per-frame shot probability over each live segment (8 s windows, 50% overlap, averaged),
    then the max per 0.5 s on the same span rounds 2-5 scored. -> [(times, scores, start, end)]"""
    import torch
    out = []
    for seg in meta["segments"]:
        n = seg["frames"]
        if max_seconds:
            n = min(n, int(max_seconds * FPS))
        if n < 2 * GRID * FPS + (LEAD + TAIL) * FPS:
            continue
        prob, cnt = np.zeros(n, np.float32), np.zeros(n, np.float32)
        last = max(n - CLIP, 0)
        starts = list(range(0, last + 1, CLIP // 2))
        if starts[-1] != last:
            starts.append(last)
        k = 0
        while k < len(starts):
            c0 = starts[k]
            group = [s for s in starts[k:] if s < c0 + chunk]
            frames = decode_range(root / seg["path"], c0, group[-1] - c0 + CLIP, threads=8)
            for b in range(0, len(group), batch):
                ss = group[b: b + batch]
                clips = []
                for s in ss:
                    c = frames[s - c0: s - c0 + CLIP]
                    if S.tracked_side(film, seg["start"] + (s + CLIP / 2) / FPS) < 0:
                        c = c[:, :, ::-1]
                    clips.append(c)
                x = to_input(torch.from_numpy(np.ascontiguousarray(np.stack(clips))), device)
                with torch.no_grad():
                    p = torch.sigmoid(model(x)).float().cpu().numpy()
                for s, ps in zip(ss, p):
                    m = min(CLIP, n - s)
                    prob[s: s + m] += ps[:m]
                    cnt[s: s + m] += 1
            k += len(group)
            del frames
        prob /= np.maximum(cnt, 1)
        start, end = seg["start"], seg["start"] + n / FPS
        times = np.arange(start + LEAD, end - TAIL, GRID)
        lo = np.clip(np.round((times - start - GRID / 2) * FPS).astype(int), 0, n)
        hi = np.clip(np.round((times - start + GRID / 2) * FPS).astype(int), 0, n)
        scores = np.array([prob[a:b].max() if b > a else 0.0 for a, b in zip(lo, hi)], np.float32)
        out.append((times, scores, start, end))
    return out


# ---------------------------------------------------------------- Modal functions

@app.function(image=image, volumes={"/data": volume}, secrets=[modal.Secret.from_name("goalieiq-r2")],
              cpu=4.0, memory=8192, timeout=3 * 3600, retries=1)
def prepare(film):
    volume.reload()
    vid = str(film["video_id"])
    meta_path = ROOT / "meta" / f"{vid}.json"
    if meta_path.exists():
        return json.loads(meta_path.read_text())
    src = S.r2_url(film["storage_path"])
    segs = []
    for n, (a, b) in enumerate(S.live_segments(film)):
        out = ROOT / "film" / f"{vid}_{n}.mp4"
        if not out.exists():
            make_copy(src, a, b - a, out)
        segs.append(dict(n=n, start=a, end=b, frames=frame_count(out), path=f"film/{vid}_{n}.mp4"))
    meta_path.parent.mkdir(parents=True, exist_ok=True)
    meta = dict(video_id=vid, segments=segs)
    meta_path.write_text(json.dumps(meta))
    volume.commit()
    return meta


@app.function(image=image, gpu="A10G", volumes={"/data": volume}, cpu=8.0, memory=32768, timeout=6 * 3600)
def train_fold(label, train_films, test_films, hard_negs, epochs=15, steps=330, batch=6, max_seconds=None):
    """Train on train_films, score test_films. Checkpoints every epoch and every scored film,
    so a GPU preemption costs at most one epoch."""
    import shutil
    import torch
    volume.reload()
    log = lambda m: print(f"[{label}] {m}", flush=True)
    log(f"GPU: {torch.cuda.get_device_name(0)}")
    safe = label.replace("/", "_")
    for d in ("ckpt", "scores"):
        (ROOT / d).mkdir(parents=True, exist_ok=True)
    ckpt, partial = ROOT / "ckpt" / f"{safe}.pt", ROOT / "ckpt" / f"{safe}_scores.json"
    ids = list(train_films) + [str(f["video_id"]) for f in test_films]
    metas = {v: json.loads((ROOT / "meta" / f"{v}.json").read_text()) for v in ids}
    local = Path("/tmp/dense")
    trained = ckpt.exists() and torch.load(ckpt, map_location="cpu", weights_only=False)["epoch"] >= epochs
    if not trained:
        t0 = time.time()
        for v in train_films:
            for seg in metas[v]["segments"]:
                dst = local / seg["path"]
                dst.parent.mkdir(parents=True, exist_ok=True)
                if not dst.exists():
                    shutil.copy(ROOT / seg["path"], dst)
        log(f"copied training film locally in {time.time() - t0:.0f}s")
    model = train_core(train_films, metas, hard_negs, local, epochs=epochs, steps=steps, batch=batch, log=log,
                       ckpt=ckpt, on_save=volume.commit)
    if not trained:
        log(f"peak GPU memory {torch.cuda.max_memory_allocated() / 2**30:.1f} GB")
    out = json.loads(partial.read_text()) if partial.exists() else {}
    t0 = time.time()
    for f in test_films:
        v = str(f["video_id"])
        if v in out:
            continue
        segs = score_film(model, f, metas[v], ROOT, max_seconds=max_seconds)
        out[v] = [(t.round(2).tolist(), s.round(4).tolist(), a, b) for t, s, a, b in segs]
        partial.write_text(json.dumps(out))
        volume.commit()
    log(f"scored {len(test_films)} held-out films in {time.time() - t0:.0f}s")
    (ROOT / "scores" / f"{safe}.json").write_text(json.dumps(out))
    volume.commit()
    return label, len(out)


@app.function(image=image, volumes={"/data": volume}, timeout=600)
def load_scores():
    volume.reload()
    folder = ROOT / "scores"
    if not folder.exists():
        return {}
    return {p.stem.replace("_", "/", 1): json.loads(p.read_text()) for p in folder.glob("*.json")}


# ---------------------------------------------------------------- local driver

THRESHOLDS = np.round(np.concatenate([[0.005, 0.01], np.arange(0.02, 0.99, 0.01)]), 3)


def arrays(res):
    return {v: [(np.array(t), np.array(s), a, b) for t, s, a, b in segs] for v, segs in res.items()}


def sweep_on(results, films, ids):
    per, minutes = [], 0.0
    for v in ids:
        for t, s, a, b in results[v]:
            if len(t) < 3:
                continue
            per.append((t, s, [x for x in films[v]["shot_times"] if t[0] - 1 <= x <= t[-1] + 1]))
            minutes += (t[-1] - t[0] + GRID) / 60
    return S.sweep(per, THRESHOLDS), minutes / 60


def summary(rows, hours):
    def at_recall(r):
        ok = [x for x in rows if x["recall"] >= r]
        x = min(ok, key=lambda x: x["fp"]) if ok else None
        return "—" if x is None else f"{x['fp'] / hours:.0f} ({x['precision']:.0%} precise)"
    def found_at(extra):
        ok = [x for x in rows if x["fp"] / hours <= extra]
        return "—" if not ok else f"{max(ok, key=lambda x: x['recall'])['recall']:.0%}"
    best = max(rows, key=lambda x: x["f1"])
    return [f"{best['f1']:.2f}", *(at_recall(r) for r in (0.9, 0.8, 0.7, 0.6, 0.5)),
            *(found_at(e) for e in (100, 60, 30))]


def main():
    import launch as L
    ap = argparse.ArgumentParser()
    ap.add_argument("--prepare", action="store_true", help="make 12.5 fps copies of films not prepared yet")
    ap.add_argument("--smoke", action="store_true", help="3 films, 1 short epoch, 5 min scored: checks speed + memory")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--run", default="d1", help="name for this run's results (no _ or /)")
    ap.add_argument("--only", default="1,2,3", help="folds to start, e.g. 1,2,3")
    ap.add_argument("--epochs", type=int, default=15)
    ap.add_argument("--steps", type=int, default=330)
    args = ap.parse_args()
    if "_" in args.run or "/" in args.run:
        sys.exit("--run must not contain _ or /")

    films = L.load_films(True)
    fold_of, k = S.goalie_folds(films, 5)
    hard = json.loads((S.REPO / "ml" / "data" / "hard_negs_r4.json").read_text())
    vol = modal.Volume.from_name("goalieiq-ml")
    fn = lambda name: modal.Function.from_name("goalieiq-dense", name)

    def prepared():
        try:
            return {e.path.split("/")[-1][:-5] for e in vol.iterdir(f"{SUB}/meta") if e.path.endswith(".json")}
        except Exception:
            return set()

    if args.prepare:
        have = prepared()
        todo = sorted((f for v, f in films.items() if v not in have), key=lambda f: f["duration_seconds"] or 1e9)
        for f in todo:                                   # shortest first: the smoke test's films are ready soonest
            fn("prepare").spawn(f)
        print(f"{len(have)} films already prepared; started {len(todo)} in the cloud. Re-run --status to follow.")
        return

    if args.status:
        done = fn("load_scores").remote()
        print(f"{len(prepared())}/{len(films)} films prepared; finished runs: {sorted(done) or 'none'}")
        return

    if args.smoke:
        by_goalie = {}
        for v in sorted(films, key=lambda v: films[v]["duration_seconds"] or 1e9):
            if films[v].get("net_sides") and not films[v]["net_sides"].get("exclude"):
                by_goalie.setdefault(films[v]["user_id"], v)
        pick = list(by_goalie.values())[:3]
        print("smoke test on films", pick)
        t0 = time.time()
        while not set(pick) <= prepared():               # --prepare makes them (shortest films first)
            if time.time() - t0 > 3600:
                sys.exit("smoke films still not prepared after an hour; run --prepare first")
            time.sleep(20)
        label, n = fn("train_fold").remote("smoke/fold0", {v: films[v] for v in pick[:2]}, [films[pick[2]]],
                                           {v: hard.get(v, []) for v in pick[:2]}, epochs=2, steps=30,
                                           max_seconds=300)
        print(f"smoke test finished: {label}, {n} film scored")
        return

    if args.report:
        mine = {lab: r for lab, r in fn("load_scores").remote().items() if lab.startswith(args.run + "/")}
        if not mine:
            sys.exit(f"No results for run {args.run} yet.")
        folds = sorted(lab.split("/")[-1] for lab in mine)
        dense = {}
        for r in mine.values():
            dense.update(arrays(r))
        r4 = {}
        for lab, r in modal.Function.from_name("goalieiq-shots", "load_scores").remote().items():
            if lab.startswith("r4net100%/") and lab.split("/")[-1] in folds:
                r4.update(arrays(r))
        common = sorted(set(dense) & set(r4))
        head = ["", "Best F1", "Extras/h at 90% found", "at 80%", "at 70%", "at 60%", "at 50%",
                "Found at ≤100 extras/h", "≤60/h", "≤30/h"]
        lines = [f"# Round 6 ({args.run}): dense spotting vs round 4", "",
                 f"{len(common)} films, folds {', '.join(folds)}; whole goalies held out; a found shot is within ±2 s.", "",
                 "| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
        for name, res in (("Round 4 (live)", r4), (f"Round 6 ({args.run})", dense)):
            rows, hours = sweep_on(res, films, common)
            lines.append(f"| {name} | " + " | ".join(summary(rows, hours)) + " |")
        lines += ["", f"{hours:.1f} h of live film, {sum(1 for _ in common)} films."]
        out_dir = S.REPO / "ml" / "data" / f"eval_dense_{args.run}"
        _, h = S.evaluate_core({v: dense[v] for v in common}, films, out_dir, f"Round 6 ({args.run}): dense spotting")
        (out_dir / "vs_round4.md").write_text("\n".join(lines) + "\n")
        print("\n".join(lines))
        print(f"\nFull report: {out_dir / 'report.md'}")
        return

    done = fn("load_scores").remote()
    have = prepared()
    missing = [v for v in films if v not in have]
    if missing:
        sys.exit(f"{len(missing)} films aren't prepared yet; run --prepare and wait (--status).")
    for f in sorted(int(x) - 1 for x in args.only.split(",")):
        label = f"{args.run}/fold{f + 1}"
        if label in done:
            print(f"{label} already finished")
            continue
        train = {v: films[v] for v in films if fold_of[v] != f}
        test = [films[v] for v in films if fold_of[v] == f]
        call = fn("train_fold").spawn(label, train, test, {v: hard.get(v, []) for v in train},
                                      epochs=args.epochs, steps=args.steps)
        print(f"started {label}: {len(train)} training films, {len(test)} held out ({call.object_id})")
    print("Running in the cloud; safe to close the laptop. Check with --status, then --report.")


if __name__ == "__main__":
    main()
