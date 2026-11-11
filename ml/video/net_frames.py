"""
Contact sheets for labelling which side of the picture the tracked goalie's
net is on, per period: frames at tagged shot moments (the net being shot on
is the tracked goalie's). Reads film from R2 (keys from .env).

    ml/.venv/bin/python ml/video/net_frames.py     -> ml/data/net_frames/<video>.jpg
"""
import json, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from io import BytesIO
from pathlib import Path

import boto3
from botocore.config import Config
from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "ml" / "data" / "net_frames"
for line in (REPO / ".env").read_text().splitlines():
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1); os.environ.setdefault(k.strip(), v.strip())
s3 = boto3.client("s3", endpoint_url=f"https://{os.environ['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
                  aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"], aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
                  region_name="auto", config=Config(signature_version="s3v4"))
FF = str(REPO / "node_modules" / "ffmpeg-static" / "ffmpeg")
TW, TH = 400, 225


def period_at(pm, t):
    p = "1"
    for name in ("2", "3", "OT"):
        if isinstance(pm.get(name), (int, float)) and t >= pm[name]:
            p = name
    return p


def frame(url, t):
    out = subprocess.run([FF, "-hide_banner", "-loglevel", "error", "-ss", str(t), "-i", url, "-frames:v", "1",
                          "-vf", f"scale={TW}:{TH}", "-f", "image2", "-c:v", "mjpeg", "-"], capture_output=True)
    return Image.open(BytesIO(out.stdout)).convert("RGB") if out.stdout else Image.new("RGB", (TW, TH), "gray")


def sheet(film):
    vid = str(film["video_id"])
    url = s3.generate_presigned_url("get_object", Params={"Bucket": os.environ["R2_BUCKET_NAME"], "Key": film["storage_path"]}, ExpiresIn=3600)
    pm = film.get("period_marks") or {}
    by_p = {}
    for t in film["shot_times"]:
        by_p.setdefault(period_at(pm, t), []).append(t)
    rows = []
    for p in ("1", "2", "3", "OT"):
        ts = by_p.get(p, [])
        if not ts:
            continue
        pick = [ts[int(i * (len(ts) - 1) / 2)] for i in range(3)] if len(ts) >= 3 else ts
        rows.append((p, pick))
    img = Image.new("RGB", (TW * 3, (TH + 22) * len(rows)), "white")
    d = ImageDraw.Draw(img)
    for r, (p, pick) in enumerate(rows):
        y = r * (TH + 22)
        d.text((6, y + 4), f"video {vid}  period {p}", fill="black")
        for c, t in enumerate(pick):
            img.paste(frame(url, t), (c * TW, y + 22))
            d.text((c * TW + 260, y + 4), f"t={t:.0f}s", fill="black")
    img.save(OUT / f"{vid}.jpg", quality=80)
    return vid, [p for p, _ in rows]


films = []
for line in (REPO / "ml" / "data" / "games.jsonl").read_text().splitlines():
    g = json.loads(line)
    films += g["film"]
OUT.mkdir(parents=True, exist_ok=True)
with ThreadPoolExecutor(6) as ex:
    for vid, ps in ex.map(sheet, films):
        print(vid, "periods", ps, flush=True)
