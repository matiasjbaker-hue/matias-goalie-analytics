"""
Step 2 of ml/AUDIT.md: a full-resolution look at the net, as a second opinion
on round 4's flagged moments. Feasibility version: frozen features, no
fine-tuning (round 6 showed a big model memorizes ~1,400 shots per fold).

For every round-4 candidate (ml/data/audio/candidates.json, 17,528 moments,
1,562 real shots, each scored by a round-4 model that never saw that goalie):

  detect   (GPU)  OWLv2 finds the tracked net at t-1, t+1, t+3 s on the
                  12.5 fps 640x360 copies round 6 made (/data/dense/film)
  crop     (CPU)  ffmpeg cuts t-2..t+4 s from the ORIGINAL film at 12.5 fps,
                  a square around the net (3.5x its width), 160x160, so the
                  goalie and the crease are big and the puck is ~2 px
  features (GPU)  Kinetics R(2+1)D-18, frozen: 512 numbers for "at" (t-1..t+1)
                  and 512 for "after" (t+1..t+4)
  --eval   (here) logistic regression on round 4's score + those numbers,
                  cross-validated by whole goalie (same folds), extras/h at
                  fixed recall vs round 4 alone

    ml/.venv/bin/modal deploy ml/video/stage2_modal.py
    ml/.venv/bin/python ml/video/stage2_modal.py --smoke        # 2 films, writes crops to look at
    ml/.venv/bin/python ml/video/stage2_modal.py --launch       # all films (~$4-5), safe to close the laptop
    ml/.venv/bin/python ml/video/stage2_modal.py --status
    ml/.venv/bin/python ml/video/stage2_modal.py --eval
"""

import argparse
import io
import json
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import modal

sys.path.insert(0, str(Path(__file__).resolve().parent))
import shots_modal as S  # noqa: E402

OWL = "google/owlv2-base-patch16-ensemble"
QUERIES = ["a hockey goal net", "an ice hockey goaltender"]
DFPS, DW, DH = 12.5, 640, 360          # the round-6 copies
LOOK = (-1.0, 1.0, 3.0)                # seconds around the moment to find the net
WIN = (-2.0, 4.0)                      # clip span around the moment
CROP_OUT = 160
NET_SCALE = 3.5                        # crop side = 3.5x the net's width
SUB = Path("/data/stage2")

app = modal.App("goalieiq-stage2")
image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("ffmpeg")
    .pip_install("torch", "torchvision", "transformers", "pillow", "numpy", "boto3", "scipy")
    .run_commands(f"python -c \"from transformers import Owlv2Processor as P, Owlv2ForObjectDetection as M; "
                  f"P.from_pretrained('{OWL}'); M.from_pretrained('{OWL}')\"",
                  "python -c \"from torchvision.models.video import r2plus1d_18, R2Plus1D_18_Weights as W; "
                  "r2plus1d_18(weights=W.KINETICS400_V1)\"",
                  "python -c \"from transformers import ASTFeatureExtractor as F, ASTForAudioClassification as M; "
                  "F.from_pretrained('MIT/ast-finetuned-audioset-10-10-0.4593'); M.from_pretrained('MIT/ast-finetuned-audioset-10-10-0.4593')\"")
    .add_local_python_source("shots_modal")
)
volume = modal.Volume.from_name("goalieiq-ml", create_if_missing=True)


def frame_at(path, idx):
    """One frame of a 12.5 fps copy as RGB uint8 (DH, DW, 3)."""
    t = max(idx - 0.49, 0) / DFPS
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", f"{t:.3f}", "-i", str(path),
                          "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                         capture_output=True, check=True).stdout
    a = np.frombuffer(raw, np.uint8)
    return a.reshape(DH, DW, 3) if a.size == DH * DW * 3 else None


def pick_box(dets, side, goalcam):
    """The tracked net among OWLv2's boxes ([x0, y0, x1, y1, score, query], 640x360 coords)."""
    ok = []
    for x0, y0, x1, y1, sc, q in dets:
        w, h = x1 - x0, y1 - y0
        if q != 0 or w < 4 or h < 4 or sc < 0.10:
            continue
        if not goalcam and (w * h > 0.30 * DW * DH or not 0.6 <= w / h <= 4.0):
            continue                                   # overlays, boards, giant boxes
        ok.append((x0, y0, x1, y1, sc))
    if not ok:
        return None
    if goalcam:                                        # camera behind the tracked net: the big one
        return max(ok, key=lambda b: (b[2] - b[0]) * (b[3] - b[1]) * b[4])
    if side:
        on = [b for b in ok if ((b[0] + b[2]) / 2 < DW / 2) == (side > 0)]
        ok = on or ok
    return max(ok, key=lambda b: b[4])


@app.function(image=image, gpu="A10G", volumes={"/data": volume}, cpu=8.0, memory=16384, timeout=3 * 3600)
def detect(jobs):
    """jobs: [{video_id, cands:[t...], sides:[...], goalcam}] -> /data/stage2/boxes/<id>.json"""
    from concurrent.futures import ThreadPoolExecutor
    import torch
    from PIL import Image
    from transformers import Owlv2Processor, Owlv2ForObjectDetection
    volume.reload()
    proc = Owlv2Processor.from_pretrained(OWL)
    model = Owlv2ForObjectDetection.from_pretrained(OWL).cuda().eval()
    post = getattr(proc, "post_process_grounded_object_detection", None) or proc.post_process_object_detection
    done = 0
    for job in jobs:
        v = job["video_id"]
        out_path = SUB / "boxes" / f"{v}.json"
        if out_path.exists():
            continue
        meta = json.loads((Path("/data/dense/meta") / f"{v}.json").read_text())
        want = []                                      # (cand index, look index, copy path, frame)
        for i, t in enumerate(job["cands"]):
            seg = next((s for s in meta["segments"] if s["start"] <= t <= s["start"] + s["frames"] / DFPS), None)
            if seg is None:
                continue
            for k, dt in enumerate(LOOK):
                idx = int(np.clip(round((t + dt - seg["start"]) * DFPS), 0, seg["frames"] - 1))
                want.append((i, k, Path("/data/dense") / seg["path"], idx))
        with ThreadPoolExecutor(8) as pool:            # ffmpeg seeks in parallel
            frames = list(pool.map(lambda w: frame_at(w[2], w[3]), want))
        queue = [(i, k, Image.fromarray(im)) for (i, k, _, _), im in zip(want, frames) if im is not None]
        boxes = [[None] * len(LOOK) for _ in job["cands"]]
        for b in range(0, len(queue), 16):
            chunk = queue[b: b + 16]
            ims = [c[2] for c in chunk]
            inputs = proc(text=[QUERIES] * len(ims), images=ims, return_tensors="pt").to("cuda")
            with torch.no_grad(), torch.autocast("cuda", dtype=torch.float16):
                o = model(**inputs)
            o.logits, o.pred_boxes = o.logits.float(), o.pred_boxes.float()
            sz = torch.tensor([[DW, DW]] * len(ims), device="cuda")       # OWLv2 pads to a square
            try:
                res = post(outputs=o, threshold=0.05, target_sizes=sz)
            except TypeError:
                res = proc.post_process_object_detection(outputs=o, threshold=0.05, target_sizes=sz)
            for (i, k, _), r in zip(chunk, res):
                dets = [[*map(float, bb), float(sc), int(lb)] for bb, sc, lb in
                        zip(r["boxes"].cpu(), r["scores"].cpu(), r["labels"].cpu())]
                boxes[i][k] = pick_box(dets, job["sides"][i], job["goalcam"])
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps({"video_id": v, "boxes": boxes}))
        volume.commit()
        done += 1
        print(f"{v}: {len(job['cands'])} moments, net found at {sum(any(b) for b in boxes)}", flush=True)
    return done


def crop_plan(boxes, side, goalcam, ow, oh):
    """Square crop in original pixels from the boxes found around the moment."""
    got = [b for b in boxes if b]
    sx, sy = ow / DW, oh / DH
    if got:
        cx = float(np.median([(b[0] + b[2]) / 2 for b in got])) * sx
        cy = float(np.median([(b[1] + b[3]) / 2 for b in got])) * sy
        nw = float(np.median([b[2] - b[0] for b in got])) * sx
        size = NET_SCALE * nw
        if not goalcam:                                # lean toward the ice in front of the net
            toward = 1 if side > 0 else -1 if side < 0 else (1 if cx < ow / 2 else -1)
            cx += 0.2 * size * toward
        found = True
    else:                                              # no net: the tracked half, a bit above centre
        cx = ow * (0.25 if side > 0 else 0.75 if side < 0 else 0.5)
        cy, size, found = 0.45 * oh, 0.5 * oh, False
    size = int(min(max(size, 0.18 * oh), 0.95 * oh, ow))
    x0 = int(min(max(cx - size / 2, 0), ow - size))
    y0 = int(min(max(cy - size / 2, 0), oh - size))
    return x0, y0, size, found


@app.function(image=image, volumes={"/data": volume}, secrets=[modal.Secret.from_name("goalieiq-r2")],
              cpu=4.0, memory=4096, timeout=3 * 3600, retries=1)
def crop(job):
    """job: {video_id, storage_path, cands, sides, goalcam} -> /data/stage2/clips/<id>/<i>.mp4 + plan json."""
    volume.reload()
    v = job["video_id"]
    plan_path = SUB / "plans" / f"{v}.json"
    if plan_path.exists():
        return v
    boxes = json.loads((SUB / "boxes" / f"{v}.json").read_text())["boxes"]
    url = S.r2_url(job["storage_path"])
    probe = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                       "stream=width,height", "-of", "json", url], capture_output=True, text=True).stdout)
    ow, oh = probe["streams"][0]["width"], probe["streams"][0]["height"]
    out_dir = SUB / "clips" / v
    out_dir.mkdir(parents=True, exist_ok=True)
    from concurrent.futures import ThreadPoolExecutor
    plans = []
    for i, t in enumerate(job["cands"]):
        x0, y0, size, found = crop_plan(boxes[i], job["sides"][i], job["goalcam"], ow, oh)
        plans.append(dict(t=t, x0=x0, y0=y0, size=size, found=found, start=max(t + WIN[0], 0.0)))

    def cut(i):
        p, out = plans[i], out_dir / f"{i}.mp4"
        if out.exists():
            return
        r = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-threads", "2",
                            "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "10",
                            "-ss", f"{p['start']:.2f}", "-i", url, "-t", f"{WIN[1] - WIN[0]:.2f}", "-an",
                            "-vf", f"fps={DFPS},crop={p['size']}:{p['size']}:{p['x0']}:{p['y0']},scale={CROP_OUT}:{CROP_OUT}",
                            "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", str(out)], capture_output=True)
        if r.returncode:
            print(f"{v} #{i}: ffmpeg failed: {r.stderr[-200:]!r}", flush=True)
    with ThreadPoolExecutor(3) as pool:                # mostly waiting on R2, so overlap the downloads
        list(pool.map(cut, range(len(plans))))
    plan_path.parent.mkdir(parents=True, exist_ok=True)
    plan_path.write_text(json.dumps({"video_id": v, "w": ow, "h": oh, "plans": plans}))
    volume.commit()
    return v


def clip_frames(path, n_expected):
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(path), "-f", "rawvideo",
                          "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
    a = np.frombuffer(raw, np.uint8)
    if a.size < CROP_OUT * CROP_OUT * 3:
        return None
    a = a[: a.size // (CROP_OUT * CROP_OUT * 3) * CROP_OUT * CROP_OUT * 3].reshape(-1, CROP_OUT, CROP_OUT, 3)
    if len(a) < n_expected:
        a = np.concatenate([a, np.repeat(a[-1:], n_expected - len(a), 0)])
    return a[:n_expected]


@app.function(image=image, gpu="A10G", volumes={"/data": volume}, cpu=8.0, memory=16384, timeout=3 * 3600)
def features(jobs):
    """Frozen Kinetics R(2+1)D-18 features of each clip: 'at' (t-1..t+1) and 'after' (t+1..t+4), 16 frames each.
    Clips are mirrored so the tracked net is on the left, as in rounds 3-5."""
    import torch
    from torchvision.models.video import r2plus1d_18, R2Plus1D_18_Weights
    volume.reload()
    m = r2plus1d_18(weights=R2Plus1D_18_Weights.KINETICS400_V1)
    m.fc = torch.nn.Identity()
    m = m.cuda().eval()
    mean = torch.tensor(S.MEAN, device="cuda").view(1, 3, 1, 1, 1)
    std = torch.tensor(S.STD, device="cuda").view(1, 3, 1, 1, 1)
    n = int(round((WIN[1] - WIN[0]) * DFPS))
    at_idx = np.linspace(round((-1 - WIN[0]) * DFPS), round((1 - WIN[0]) * DFPS) - 1, 16).round().astype(int)
    af_idx = np.linspace(round((1 - WIN[0]) * DFPS), n - 1, 16).round().astype(int)
    for job in jobs:
        v = job["video_id"]
        out_path = SUB / "feats" / f"{v}.npz"
        if out_path.exists():
            continue
        at, af, ok = [], [], []
        for i in range(len(job["cands"])):
            a = clip_frames(SUB / "clips" / v / f"{i}.mp4", n)
            if a is None:
                at.append(np.zeros(512, np.float16)); af.append(np.zeros(512, np.float16)); ok.append(False)
                continue
            if job["sides"][i] < 0 and not job["goalcam"]:
                a = a[:, :, ::-1]
            x = torch.from_numpy(np.ascontiguousarray(np.stack([a[at_idx], a[af_idx]]))).cuda()
            x = x.float().div(255).permute(0, 4, 1, 2, 3)          # [2, 3, T, H, W]
            with torch.no_grad(), torch.autocast("cuda", dtype=torch.bfloat16):
                f = m((x - mean) / std).float().cpu().numpy()
            at.append(f[0].astype(np.float16)); af.append(f[1].astype(np.float16)); ok.append(True)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        np.savez(out_path, at=np.stack(at), after=np.stack(af), ok=np.array(ok))
        volume.commit()
        print(f"{v}: features for {sum(ok)}/{len(ok)} clips", flush=True)
    return len(jobs)


FT_T, FT_CROP = 32, 144            # fine-tuning input: 32 frames, t-1 s .. t+2.8 s (~8 fps), 144x144
FT_IDX = np.round(np.linspace((-1.0 - WIN[0]) * DFPS, (2.8 - WIN[0]) * DFPS, FT_T)).astype(int)


@app.function(image=image, gpu="A10G", volumes={"/data": volume}, cpu=8.0, memory=32768, timeout=4 * 3600)
def finetune(fold, jobs, labels, folds, epochs=8, batch=16):
    """Fine-tune Kinetics R(2+1)D on the close-ups of every film outside `fold` (round 4's recipe:
    8 epochs, low backbone learning rate, dropout), then score the held-out films' close-ups.
    -> /data/stage2/oof/fold<k>.json {video_id: [score per candidate]}"""
    import shutil
    import torch
    from torch.utils.data import Dataset, DataLoader
    from torchvision.models.video import r2plus1d_18, R2Plus1D_18_Weights
    volume.reload()
    out_path = SUB / ("final_closeup.pt" if fold < 0 else f"oof/fold{fold}.json")   # fold -1: every film, for Review
    if out_path.exists():
        return fold
    log = lambda m: print(f"[fold{fold}] {m}", flush=True)
    local, t0 = Path("/tmp/s2"), time.time()
    for j in jobs:
        src, dst = SUB / "clips" / j["video_id"], local / j["video_id"]
        if src.exists() and not dst.exists():
            shutil.copytree(src, dst)
    log(f"copied clips in {time.time() - t0:.0f}s")
    n = int(round((WIN[1] - WIN[0]) * DFPS))
    items = []                                         # (path, label, mirror, train?, video, index)
    for j in jobs:
        v = j["video_id"]
        for i, lab in enumerate(labels[v]):
            p = local / v / f"{i}.mp4"
            if p.exists():
                items.append((str(p), float(lab), bool(j["sides"][i] < 0 and not j["goalcam"]), fold < 0 or folds[v] != fold, v, i))
    train, test = [it for it in items if it[3]], [it for it in items if not it[3]]
    n_pos = sum(it[1] for it in train)
    log(f"train {len(train)} close-ups ({int(n_pos)} shots), test {len(test)}")

    class Clips(Dataset):
        def __init__(self, items, aug):
            self.items, self.aug = items, aug

        def __len__(self):
            return len(self.items)

        def __getitem__(self, k):
            path, lab, mirror = self.items[k][:3]
            a = clip_frames(Path(path), n)
            if a is None:
                a = np.zeros((n, CROP_OUT, CROP_OUT, 3), np.uint8)
            shift = np.random.randint(-2, 3) if self.aug else 0
            a = a[np.clip(FT_IDX + shift, 0, n - 1)]
            if mirror:
                a = a[:, :, ::-1]
            m = CROP_OUT - FT_CROP
            y0, x0 = (np.random.randint(0, m + 1, 2) if self.aug else (m // 2, m // 2))
            a = a[:, y0: y0 + FT_CROP, x0: x0 + FT_CROP]
            return torch.from_numpy(np.ascontiguousarray(a)), torch.tensor(lab, dtype=torch.float32)

    torch.backends.cudnn.benchmark = True
    model = r2plus1d_18(weights=R2Plus1D_18_Weights.KINETICS400_V1)
    model.fc = torch.nn.Sequential(torch.nn.Dropout(0.5), torch.nn.Linear(512, 1))
    model = model.cuda()
    head = list(model.fc.parameters())
    body = [p for name, p in model.named_parameters() if not name.startswith("fc.")]
    opt = torch.optim.AdamW([dict(params=body, lr=1e-4), dict(params=head, lr=1e-3)], weight_decay=1e-4)
    loader = DataLoader(Clips(train, True), batch_size=batch, shuffle=True, num_workers=8, pin_memory=True,
                        drop_last=True, persistent_workers=True)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=[1e-4, 1e-3], total_steps=epochs * len(loader), pct_start=0.15)
    loss_fn = torch.nn.BCEWithLogitsLoss(pos_weight=torch.tensor((len(train) - n_pos) / max(n_pos, 1), device="cuda"))
    mean = torch.tensor(S.MEAN, device="cuda").view(1, 3, 1, 1, 1)
    std = torch.tensor(S.STD, device="cuda").view(1, 3, 1, 1, 1)
    prep = lambda x: (x.cuda(non_blocking=True).float().div(255).permute(0, 4, 1, 2, 3) - mean) / std
    for ep in range(epochs):
        model.train()
        tot, seen, t0 = 0.0, 0, time.time()
        for x, y in loader:
            x = prep(x) * torch.empty(x.shape[0], 1, 1, 1, 1, device="cuda").uniform_(0.85, 1.15)
            with torch.autocast("cuda", dtype=torch.bfloat16):
                loss = loss_fn(model(x).float().squeeze(1), y.cuda())
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step()
            sched.step()
            tot += loss.item() * len(y); seen += len(y)
        log(f"epoch {ep + 1}/{epochs}: loss {tot / max(seen, 1):.4f} ({time.time() - t0:.0f}s)")
    model.eval()
    if fold < 0:
        torch.save({"model": model.state_dict(), "films": len(jobs), "clips": len(train), "frames": FT_T, "crop": FT_CROP},
                   out_path)
        volume.commit()
        log(f"saved the final close-up model ({len(train)} close-ups)")
        return fold
    scores, k = {}, 0
    for x, _ in DataLoader(Clips(test, False), batch_size=32, shuffle=False, num_workers=8):
        with torch.no_grad(), torch.autocast("cuda", dtype=torch.bfloat16):
            p = torch.sigmoid(model(prep(x)).float().squeeze(1)).cpu().numpy()
        for s in p:
            _, _, _, _, v, i = test[k]
            scores.setdefault(v, {})[i] = float(s)
            k += 1
    out = {v: [d.get(i) for i in range(len(labels[v]))] for v, d in scores.items()}
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out))
    volume.commit()
    log(f"scored {len(test)} held-out close-ups")
    return fold


# ---------------------------------------------------------------- Review: re-score one new game

AST = "MIT/ast-finetuned-audioset-10-10-0.4593"
SR = 16000
SOUND_WIN = {"at": (-1.5, 1.5), "after": (1.5, 4.5)}   # as ml/video/audio_modal.py
GOALCAM_AREA = 0.05            # median net box > 5% of the picture: a camera behind the net


def lin(m, x):
    """A logistic regression exported by export_stack(): decision value(s) for feature rows x."""
    x = np.atleast_2d(np.asarray(x, np.float64))
    return ((x - np.array(m["mean"])) / np.array(m["scale"])) @ np.array(m["coef"]) + m["intercept"]


def orig_frame(url, t):
    """One frame of the original film at t seconds, scaled to 640x360 (as the round-6 copies)."""
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", f"{max(t, 0):.2f}", "-i", url,
                          "-frames:v", "1", "-vf", f"scale={DW}:{DH}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                         capture_output=True).stdout
    a = np.frombuffer(raw, np.uint8)
    return a.reshape(DH, DW, 3) if a.size == DH * DW * 3 else None


@app.function(image=image, gpu="A10G", volumes={"/data": volume}, secrets=[modal.Secret.from_name("goalieiq-r2")],
              cpu=8.0, memory=16384, timeout=3600)
def rescore(film, shots):
    """Second opinion on round 4's moments for one game, for Review's "Find shots".

    film: {video_id, storage_path, duration_seconds, period_marks}; shots: [{t, score}] from round 4.
    Returns the same list with "s2": the stacked probability that it's a shot on goal (round 4 +
    net close-ups + sound, exactly as evaluated in ml/AUDIT.md), and a summary."""
    from concurrent.futures import ThreadPoolExecutor
    import torch
    from PIL import Image
    from torchvision.models.video import r2plus1d_18, R2Plus1D_18_Weights
    from transformers import ASTFeatureExtractor, ASTForAudioClassification, Owlv2Processor, Owlv2ForObjectDetection
    t_start = time.time()
    volume.reload()
    stack = json.loads((SUB / "stack.json").read_text())
    shots = [dict(s) for s in shots]
    ts = [float(s["t"]) for s in shots]
    if not ts:
        return {"shots": shots, "summary": {}}
    film = dict(film, net_sides=None)                  # live games: the net side comes from the period marks
    sides = [S.tracked_side(film, t) for t in ts]
    url = S.r2_url(film["storage_path"])
    probe = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type,width,height",
                                       "-of", "json", url], capture_output=True, text=True).stdout or "{}")
    vstream = next((st for st in probe.get("streams", []) if st.get("codec_type") == "video"), {})
    ow, oh = int(vstream.get("width") or 1920), int(vstream.get("height") or 1080)
    has_audio = any(st.get("codec_type") == "audio" for st in probe.get("streams", []))

    # 1. find the net at t-1, t+1, t+3 (frames straight from the original, scaled like the training copies)
    want = [(i, k, t + dt) for i, t in enumerate(ts) for k, dt in enumerate(LOOK)]
    with ThreadPoolExecutor(8) as pool:
        frames = list(pool.map(lambda w: orig_frame(url, w[2]), want))
    proc = Owlv2Processor.from_pretrained(OWL)
    owl = Owlv2ForObjectDetection.from_pretrained(OWL).cuda().eval()
    post = getattr(proc, "post_process_grounded_object_detection", None) or proc.post_process_object_detection
    queue = [(i, k, Image.fromarray(im)) for (i, k, _), im in zip(want, frames) if im is not None]
    raw = [[None] * len(LOOK) for _ in ts]
    for b in range(0, len(queue), 16):
        chunk = queue[b: b + 16]
        inputs = proc(text=[QUERIES] * len(chunk), images=[c[2] for c in chunk], return_tensors="pt").to("cuda")
        with torch.no_grad(), torch.autocast("cuda", dtype=torch.float16):
            o = owl(**inputs)
        o.logits, o.pred_boxes = o.logits.float(), o.pred_boxes.float()
        sz = torch.tensor([[DW, DW]] * len(chunk), device="cuda")
        try:
            res = post(outputs=o, threshold=0.05, target_sizes=sz)
        except TypeError:
            res = proc.post_process_object_detection(outputs=o, threshold=0.05, target_sizes=sz)
        for (i, k, _), r in zip(chunk, res):
            raw[i][k] = [[*map(float, bb), float(sc), int(lb)] for bb, sc, lb in
                         zip(r["boxes"].cpu(), r["scores"].cpu(), r["labels"].cpu())]
    del owl
    # Camera behind the net? The best net box after the usual filters (either side), as in the
    # analysis that set GOALCAM_AREA; the biggest raw box misfires on stray large detections.
    picked = [pick_box(dets, 0, False) for row in raw for dets in row if dets is not None]
    areas = [(p[2] - p[0]) * (p[3] - p[1]) / (DW * DH) for p in picked if p]
    goalcam = bool(areas) and float(np.median(areas)) > GOALCAM_AREA
    boxes = [[pick_box(dets, sides[i], goalcam) if dets is not None else None for dets in raw[i]] for i in range(len(ts))]

    # 2. full-resolution close-ups around the net, t-2..t+4 s
    work = Path("/tmp/rescore"); work.mkdir(parents=True, exist_ok=True)
    plans = [crop_plan(boxes[i], sides[i], goalcam, ow, oh) for i in range(len(ts))]

    def cut(i):
        x0, y0, size, _ = plans[i]
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-threads", "2",
                        "-ss", f"{max(ts[i] + WIN[0], 0):.2f}", "-i", url, "-t", f"{WIN[1] - WIN[0]:.2f}", "-an",
                        "-vf", f"fps={DFPS},crop={size}:{size}:{x0}:{y0},scale={CROP_OUT}:{CROP_OUT}",
                        "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", str(work / f"{i}.mp4")], capture_output=True)
    with ThreadPoolExecutor(4) as pool:
        list(pool.map(cut, range(len(ts))))

    # 3. close-up scores: frozen Kinetics features and the fine-tuned close-up model
    n = int(round((WIN[1] - WIN[0]) * DFPS))
    at_idx = np.linspace(round((-1 - WIN[0]) * DFPS), round((1 - WIN[0]) * DFPS) - 1, 16).round().astype(int)
    af_idx = np.linspace(round((1 - WIN[0]) * DFPS), n - 1, 16).round().astype(int)
    frozen_m = r2plus1d_18(weights=R2Plus1D_18_Weights.KINETICS400_V1)
    frozen_m.fc = torch.nn.Identity()
    frozen_m = frozen_m.cuda().eval()
    ft_m = r2plus1d_18()
    ft_m.fc = torch.nn.Sequential(torch.nn.Dropout(0.5), torch.nn.Linear(512, 1))
    ft_m.load_state_dict(torch.load(SUB / "final_closeup.pt", map_location="cpu", weights_only=False)["model"])
    ft_m = ft_m.cuda().eval()
    mean = torch.tensor(S.MEAN, device="cuda").view(1, 3, 1, 1, 1)
    std = torch.tensor(S.STD, device="cuda").view(1, 3, 1, 1, 1)
    prep = lambda a: (torch.from_numpy(np.ascontiguousarray(a)).cuda().float().div(255).permute(0, 4, 1, 2, 3) - mean) / std
    m0 = (CROP_OUT - FT_CROP) // 2
    frozen_x, ft_p = np.zeros((len(ts), 1024)), np.full(len(ts), 0.5)
    for i in range(len(ts)):
        a = clip_frames(work / f"{i}.mp4", n)
        if a is None:
            continue
        if sides[i] < 0 and not goalcam:
            a = a[:, :, ::-1]
        with torch.no_grad(), torch.autocast("cuda", dtype=torch.bfloat16):
            f = frozen_m(prep(np.stack([a[at_idx], a[af_idx]]))).float().cpu().numpy()
            p = torch.sigmoid(ft_m(prep(a[FT_IDX][None, :, m0: m0 + FT_CROP, m0: m0 + FT_CROP])).float()).item()
        frozen_x[i], ft_p[i] = np.concatenate([f[0], f[1]]), p
    del frozen_m, ft_m

    # 4. sound around each moment (AudioSet AST), relative to the whole game's loudness
    snd = np.zeros(len(ts))
    if has_audio:
        audio = np.frombuffer(subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", url, "-vn", "-ac", "1",
                                              "-ar", str(SR), "-f", "f32le", "-"], capture_output=True).stdout, np.float32)
        has_audio = audio.size > SR
    if has_audio:
        fe = ASTFeatureExtractor.from_pretrained(AST)
        ast = ASTForAudioClassification.from_pretrained(AST).cuda().eval()
        film_rms = float(np.sqrt(np.mean(audio[::50] ** 2)) + 1e-9)

        def clip(t, a, b):
            i, j = int((t + a) * SR), int((t + b) * SR)
            x = audio[max(i, 0):max(j, 0)]
            return np.pad(x, (0, (j - i) - len(x))) if len(x) < j - i else x
        feats = {}
        for name, (a, b) in SOUND_WIN.items():
            clips = [clip(t, a, b) for t in ts]
            embs, rms = [], [float(np.sqrt(np.mean(c ** 2)) + 1e-9) for c in clips]
            for k in range(0, len(clips), 32):
                x = fe(clips[k: k + 32], sampling_rate=SR, return_tensors="pt").to("cuda")
                with torch.no_grad():
                    embs.append(ast.audio_spectrogram_transformer(**x)[1].float().cpu().numpy().astype(np.float16))
            feats[name] = (np.concatenate(embs).astype(np.float32), np.array(rms))
        A = np.c_[feats["at"][0], feats["after"][0], np.log(feats["at"][1] / film_rms), np.log(feats["after"][1] / film_rms)]
        snd = lin(stack["sound"], A)
        del ast

    # 5. the stack, exactly as cross-validated
    lgt = lambda p: np.log(np.clip(p, 1e-6, 1 - 1e-6) / np.clip(1 - np.asarray(p, float), 1e-6, 1))
    r4 = lgt([float(s.get("score", 0.02)) for s in shots])
    F2 = np.c_[r4, lin(stack["frozen"], frozen_x), lgt(ft_p), snd, np.full(len(ts), float(has_audio))]
    s2 = 1 / (1 + np.exp(-lin(stack["stack"], F2)))
    for s, p in zip(shots, s2):
        s["s2"] = round(float(p), 4)
    summary = dict(moments=len(ts), goalcam=goalcam, sound=bool(has_audio), seconds=round(time.time() - t_start),
                   net_found=round(float(np.mean([any(b) for b in boxes])), 3), thresholds=stack["thresholds"],
                   kept_fewer=int((s2 >= stack["thresholds"]["fewer"]).sum()), kept_more=int((s2 >= stack["thresholds"]["more"]).sum()))
    print(f"rescore {film['video_id']}: {summary}", flush=True)
    return {"shots": shots, "summary": summary}


@app.function(image=image, timeout=6 * 3600, volumes={"/data": volume})
def pipeline(jobs):
    """Runs the three steps for every film in the cloud, so the laptop can sleep."""
    volume.reload()
    todo = [j for j in jobs if not (SUB / "boxes" / f"{j['video_id']}.json").exists()]
    if todo:
        list(detect.map([todo[i::8] for i in range(8)]))
    list(crop.map(jobs, return_exceptions=True))
    list(features.map([jobs[i::4] for i in range(4)]))
    return len(jobs)


# ---------------------------------------------------------------- local driver

def make_jobs(only=None):
    import launch as L
    films = L.load_films(True)
    cands = json.loads((S.REPO / "ml" / "data" / "audio" / "candidates.json").read_text())
    jobs = []
    for v, f in cands.items():
        if only and v not in only or not f["cands"]:
            continue
        ts = [round(c["t"], 2) for c in f["cands"]]
        ns = films[v].get("net_sides") or {}
        jobs.append(dict(video_id=v, storage_path=f["storage_path"], cands=ts,
                         sides=[S.tracked_side(films[v], t) for t in ts], goalcam=bool(ns.get("goalcam"))))
    return jobs


def evaluate():
    """Each signal becomes one out-of-fold score, then a small logistic regression stacks the
    scores (2-level stacking; a single classifier on thousands of raw features memorizes)."""
    from sklearn.linear_model import LogisticRegression
    from sklearn.metrics import roc_auc_score
    from sklearn.pipeline import make_pipeline
    from sklearn.preprocessing import StandardScaler
    import audio_eval as AE
    cands = json.loads((S.REPO / "ml" / "data" / "audio" / "candidates.json").read_text())
    vol = modal.Volume.from_name("goalieiq-ml")
    oof = {}
    for k in range(5):
        try:
            oof.update(json.loads(b"".join(vol.read_file(f"stage2/oof/fold{k}.json"))))
        except Exception:
            pass
    sound = {}
    if (AE.EMB).exists():
        _, arows = AE.load()
        for r in arows:
            sound.setdefault(r["v"], []).append(np.concatenate([r["emb"], r["loud"]]))
    rows = []
    for v, f in cands.items():
        if not f["cands"]:
            continue
        z = np.load(io.BytesIO(b"".join(vol.read_file(f"stage2/feats/{v}.npz"))))
        for i, c in enumerate(f["cands"]):
            ft = (oof.get(v) or [None] * len(f["cands"]))[i]
            rows.append(dict(v=v, fold=f["fold"], y=c["shot"], s=c["score"], ft=ft,
                             x=np.concatenate([z["at"][i], z["after"][i]]).astype(np.float32),
                             a=sound[v][i] if v in sound and len(sound[v]) == len(f["cands"]) else None))
    y = np.array([r["y"] for r in rows]); fold = np.array([r["fold"] for r in rows])
    lgt = lambda p: np.log(np.clip(p, 1e-6, 1 - 1e-6) / np.clip(1 - p, 1e-6, 1))
    r4 = lgt(np.array([r["s"] for r in rows]))

    def cv(F, mask, C):
        out = np.zeros(int(mask.sum()))
        yy, ff = y[mask], fold[mask]
        for k in sorted(set(ff)):
            tr, te = ff != k, ff == k
            m = make_pipeline(StandardScaler(), LogisticRegression(C=C, max_iter=4000, class_weight="balanced"))
            out[te] = m.fit(F[tr], yy[tr]).decision_function(F[te])
        return out
    allm = np.ones(len(y), bool)
    frozen = cv(np.stack([r["x"] for r in rows]), allm, 0.001)
    has_ft = np.array([r["ft"] is not None for r in rows])
    ft = lgt(np.array([r["ft"] if r["ft"] is not None else 0.5 for r in rows]))
    has_a = np.array([r["a"] is not None for r in rows])
    snd = np.zeros(len(y))
    if has_a.any():
        snd[has_a] = cv(np.stack([rows[i]["a"] for i in np.where(has_a)[0]]), has_a, 0.001)

    def line(name, s, mask):
        used = sorted({rows[i]["v"] for i in np.where(mask)[0]})
        n_true = sum(cands[v]["n_true"] for v in used); hours = sum(cands[v]["hours"] for v in used)
        c = AE.curve(s, y[mask], n_true, hours)
        hard = np.array([rows[i]["s"] >= 0.5 for i in np.where(mask)[0]])
        cell = lambda r: "—" if c[r] is None else f"{c[r][0]:.0f} ({c[r][1] * 100:.0f}%)"
        return (f"| {name} | {roc_auc_score(y[mask], s):.3f} | {roc_auc_score(y[mask][hard], s[hard]):.3f} | "
                + " | ".join(cell(r) for r in (0.8, 0.7, 0.6, 0.5)) + " |")
    head = ["| scorer | AUC all | AUC on confident (round 4 ≥0.5) | extras/h @80% | @70% | @60% | @50% |",
            "|---|---|---|---|---|---|---|"]
    stack = lambda cols, mask: cv(np.stack([c[mask] for c in cols], 1), mask, 1.0)
    lines = ["# Step 2: round 4 + a full-resolution look at the net (+ sound)", "",
             f"{len(set(r['v'] for r in rows))} games, {len(rows)} round-4 moments, {y.sum()} real shots. Every signal is "
             "an out-of-fold score (whole goalies held out); the stack is a small cross-validated logistic regression.",
             "", "## All games", ""] + head
    lines.append(line("round 4 only", r4, allm))
    lines.append(line("close-up, frozen features", frozen, allm))
    lines.append(line("round 4 + close-up frozen", stack([r4, frozen], allm), allm))
    if has_ft.all():
        lines.append(line("close-up, fine-tuned", ft, allm))
        lines.append(line("round 4 + close-up fine-tuned", stack([r4, ft], allm), allm))
        lines.append(line("round 4 + both close-ups", stack([r4, frozen, ft], allm), allm))
        if has_a.any():
            lines.append(line("round 4 + both close-ups + sound where there is any",
                              stack([r4, frozen, ft, snd, has_a.astype(float)], allm), allm))
    if has_a.any():
        lines += ["", f"## Games with sound ({len(set(rows[i]['v'] for i in np.where(has_a)[0]))})", ""] + head
        lines.append(line("round 4 only", r4[has_a], has_a))
        lines.append(line("round 4 + sound", stack([r4, snd], has_a), has_a))
        lines.append(line("round 4 + close-up frozen + sound", stack([r4, frozen, snd], has_a), has_a))
        if has_ft.all():
            lines.append(line("round 4 + both close-ups + sound", stack([r4, frozen, ft, snd], has_a), has_a))
    report = "\n".join(lines)
    out = S.REPO / "ml" / "data" / "stage2"
    out.mkdir(parents=True, exist_ok=True)
    (out / "report.md").write_text(report + "\n")
    print(report)


def export_stack(targets=(("fewer", 0.70), ("more", 0.80))):
    """The models Review's re-scoring uses, as plain numbers on the volume (/data/stage2/stack.json):
    frozen close-up and sound logistic regressions fit on every game, and the stack fit on the
    out-of-fold scores (as evaluated). Thresholds: the stacked probability where the cross-validated
    run found 70% ("fewer") and 80% ("more") of all tagged shots."""
    from sklearn.linear_model import LogisticRegression
    from sklearn.pipeline import make_pipeline
    from sklearn.preprocessing import StandardScaler
    import audio_eval as AE
    cands = json.loads((S.REPO / "ml" / "data" / "audio" / "candidates.json").read_text())
    vol = modal.Volume.from_name("goalieiq-ml")
    oof = {}
    for k in range(5):
        oof.update(json.loads(b"".join(vol.read_file(f"stage2/oof/fold{k}.json"))))
    _, arows = AE.load()
    sound = {}
    for r in arows:
        sound.setdefault(r["v"], []).append(np.concatenate([r["emb"], r["loud"]]))
    rows = []
    for v, f in cands.items():
        if not f["cands"]:
            continue
        z = np.load(io.BytesIO(b"".join(vol.read_file(f"stage2/feats/{v}.npz"))))
        for i, c in enumerate(f["cands"]):
            rows.append((f["fold"], c["shot"], c["score"], oof[v][i], np.concatenate([z["at"][i], z["after"][i]]).astype(np.float32),
                         sound[v][i] if v in sound and len(sound[v]) == len(f["cands"]) else None))
    fold = np.array([r[0] for r in rows]); y = np.array([r[1] for r in rows])
    lg = lambda p: np.log(np.clip(p, 1e-6, 1 - 1e-6) / np.clip(1 - np.asarray(p, float), 1e-6, 1))
    r4, ft = lg([r[2] for r in rows]), lg([r[3] for r in rows])
    X = np.stack([r[4] for r in rows])
    has_a = np.array([r[5] is not None for r in rows])
    A = np.stack([rows[i][5] for i in np.where(has_a)[0]])
    model = lambda C: make_pipeline(StandardScaler(), LogisticRegression(C=C, max_iter=4000, class_weight="balanced"))

    def cv(F, yy, ff, C):
        out = np.zeros(len(yy))
        for k in sorted(set(ff)):
            tr, te = ff != k, ff == k
            out[te] = model(C).fit(F[tr], yy[tr]).decision_function(F[te])
        return out
    frozen_oof = cv(X, y, fold, 0.001)
    snd_oof = np.zeros(len(y)); snd_oof[has_a] = cv(A, y[has_a], fold[has_a], 0.001)
    F2 = np.c_[r4, frozen_oof, ft, snd_oof, has_a.astype(float)]
    stack_oof = cv(F2, y, fold, 1.0)
    dump = lambda m: dict(mean=m[0].mean_.tolist(), scale=m[0].scale_.tolist(), coef=m[1].coef_[0].tolist(),
                          intercept=float(m[1].intercept_[0]))
    m_frozen, m_sound, m_stack = model(0.001).fit(X, y), model(0.001).fit(A, y[has_a]), model(1.0).fit(F2, y)
    n_true = sum(f["n_true"] for f in cands.values()); hours = sum(f["hours"] for f in cands.values())
    prob = 1 / (1 + np.exp(-stack_oof))
    order = np.argsort(-prob); tp = np.cumsum(y[order]); fp = np.cumsum(1 - y[order])
    thresholds, points = {}, {}
    for name, rec in targets:
        k = int(np.searchsorted(tp, rec * n_true))
        thresholds[name] = round(float(prob[order][k]), 4)
        points[name] = dict(found=round(float(tp[k] / n_true), 3), extras_per_hour=round(float(fp[k] / hours), 1),
                            real_per_hour=round(float(tp[k] / hours), 1), precision=round(float(tp[k] / (tp[k] + fp[k])), 3))
    out = dict(version=1, made=time.strftime("%Y-%m-%d"), features=["round4_logit", "frozen", "closeup_logit", "sound", "has_sound"],
               frozen=dump(m_frozen), sound=dump(m_sound), stack=dump(m_stack), thresholds=thresholds, cv=points,
               trained_on=dict(games=len(cands), moments=len(y), shots=int(y.sum())))
    local = S.REPO / "ml" / "data" / "stage2" / "stack.json"
    local.parent.mkdir(parents=True, exist_ok=True)
    local.write_text(json.dumps(out))
    with vol.batch_upload(force=True) as b:
        b.put_file(str(local), "/stage2/stack.json")
    print(json.dumps(dict(thresholds=thresholds, cv=points, stack_coef=out["stack"]["coef"]), indent=1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--launch", action="store_true")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--eval", action="store_true")
    ap.add_argument("--finetune", action="store_true", help="train + score the close-up model on 5 goalie folds (~$11)")
    ap.add_argument("--final", action="store_true", help="with --finetune: one model on every film, for Review (~$2.50)")
    ap.add_argument("--export", action="store_true", help="write the stacking models + Review thresholds to the volume")
    ap.add_argument("--out", default="", help="--smoke: folder for sample crops")
    args = ap.parse_args()
    fn = lambda name: modal.Function.from_name("goalieiq-stage2", name)
    vol = modal.Volume.from_name("goalieiq-ml")
    if args.smoke:
        jobs = make_jobs()
        jobs = sorted(jobs, key=lambda j: len(j["cands"]))[:2]
        print("smoke on", [(j["video_id"], len(j["cands"])) for j in jobs])
        t0 = time.time(); fn("detect").remote(jobs); print(f"detect {time.time() - t0:.0f}s")
        t0 = time.time(); [fn("crop").remote(j) for j in jobs]; print(f"crop {time.time() - t0:.0f}s")
        t0 = time.time(); fn("features").remote(jobs); print(f"features {time.time() - t0:.0f}s")
        if args.out:
            out = Path(args.out); out.mkdir(parents=True, exist_ok=True)
            for j in jobs:
                for i in range(0, len(j["cands"]), max(1, len(j["cands"]) // 6)):
                    data = b"".join(vol.read_file(f"stage2/clips/{j['video_id']}/{i}.mp4"))
                    (out / f"{j['video_id']}_{i}.mp4").write_bytes(data)
            print("sample clips in", out)
        return
    if args.launch:
        call = fn("pipeline").spawn(make_jobs())
        print(f"started all films in the cloud ({call.object_id}); check with --status, then --eval")
        return
    if args.status:
        for d in ("boxes", "plans", "feats"):
            try:
                n = sum(1 for _ in vol.iterdir(f"stage2/{d}"))
            except Exception:
                n = 0
            print(f"{d}: {n}/98")
        return
    if args.finetune:
        jobs = make_jobs()
        cands = json.loads((S.REPO / "ml" / "data" / "audio" / "candidates.json").read_text())
        labels = {v: [c["shot"] for c in f["cands"]] for v, f in cands.items()}
        folds = {v: f["fold"] for v, f in cands.items()}
        for k in (range(5) if not args.final else [-1]):
            print(f"fold {k}: started {fn('finetune').spawn(k, jobs, labels, folds).object_id}")
        return
    if args.eval:
        evaluate()
    if args.export:
        export_stack()


if __name__ == "__main__":
    main()
