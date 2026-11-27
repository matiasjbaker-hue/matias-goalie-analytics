"""Audio test: can the sound tell real shots from the model's near-misses?

For each film: pull the soundtrack once from R2 (16 kHz mono), cut two windows
per round-4 candidate -- "at" (t-1.5..t+1.5 s: release, puck on pads) and
"after" (t+1.5..t+4.5 s: the whistle after a freeze) -- and embed both with a
pretrained AudioSet model (AST). Returns the 768-d embeddings plus the
AudioSet class scores, so ml/video/audio_eval.py can train a small classifier.

    ml/.venv/bin/python ml/video/audio_eval.py --run      # spawn all films, collect, evaluate
"""
import os
import subprocess

import modal

app = modal.App("goalieiq-audio")
AST = "MIT/ast-finetuned-audioset-10-10-0.4593"
SR = 16000
WINDOWS = {"at": (-1.5, 1.5), "after": (1.5, 4.5)}

image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("ffmpeg")
    .pip_install("torch", "transformers", "numpy", "boto3",
                 extra_index_url="https://download.pytorch.org/whl/cpu")
    .run_commands(f"python -c \"from transformers import ASTForAudioClassification as M, ASTFeatureExtractor as F; "
                  f"M.from_pretrained('{AST}'); F.from_pretrained('{AST}')\"")
)


def r2_url(key):
    import boto3
    from botocore.config import Config
    s3 = boto3.client(
        "s3", endpoint_url=f"https://{os.environ['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"], aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
        region_name="auto", config=Config(signature_version="s3v4"))
    return s3.generate_presigned_url("get_object", Params={"Bucket": os.environ["R2_BUCKET_NAME"], "Key": key},
                                     ExpiresIn=6 * 3600)


volume = modal.Volume.from_name("goalieiq-ml", create_if_missing=True)


@app.function(image=image, volumes={"/data": volume}, secrets=[modal.Secret.from_name("goalieiq-r2")],
              cpu=4.0, memory=8192, timeout=60 * 60, retries=1)
def embed_and_save(film):
    """Deployed entry point: embed, then keep the result on the volume (audio/emb/<id>.pkl),
    so the run survives the launching computer going to sleep."""
    import pickle
    from pathlib import Path
    res = embed_film.local(film)
    out = Path("/data/audio/emb")
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{film['video_id']}.pkl").write_bytes(pickle.dumps(res))
    volume.commit()
    return res.get("has_audio")


@app.function(image=image, secrets=[modal.Secret.from_name("goalieiq-r2")], cpu=4.0, memory=8192,
              timeout=60 * 60, retries=1)
def embed_film(film):
    import numpy as np
    import torch
    from transformers import ASTFeatureExtractor, ASTForAudioClassification

    url = r2_url(film["storage_path"])
    has_audio = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries", "stream=index",
                                "-of", "csv=p=0", url], capture_output=True, text=True).stdout.strip() != ""
    if not has_audio:
        return dict(video_id=film["video_id"], has_audio=False)
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error",
                          "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "10",
                          "-i", url, "-vn", "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    audio = np.frombuffer(raw, np.float32)

    torch.set_num_threads(4)
    fe = ASTFeatureExtractor.from_pretrained(AST)
    model = ASTForAudioClassification.from_pretrained(AST).eval()

    def clip(t, a, b):
        i, j = int((t + a) * SR), int((t + b) * SR)
        x = audio[max(i, 0):max(j, 0)]
        return np.pad(x, (0, (j - i) - len(x))) if len(x) < j - i else x

    out = {}
    for name, (a, b) in WINDOWS.items():
        clips = [clip(c["t"], a, b) for c in film["cands"]]
        embs, probs, rms = [], [], []
        for k in range(0, len(clips), 32):
            batch = clips[k:k + 32]
            x = fe(batch, sampling_rate=SR, return_tensors="pt")
            with torch.no_grad():
                pooled = model.audio_spectrogram_transformer(**x)[1]
                logits = model.classifier(pooled)
            embs.append(pooled.numpy().astype(np.float16))
            probs.append(torch.sigmoid(logits).numpy().astype(np.float16))
            rms += [float(np.sqrt(np.mean(c ** 2)) + 1e-9) for c in batch]
        out[name] = dict(emb=np.concatenate(embs) if embs else np.zeros((0, 768), np.float16),
                         prob=np.concatenate(probs) if probs else np.zeros((0, 527), np.float16),
                         rms=np.array(rms, np.float32))
    film_rms = float(np.sqrt(np.mean(audio[::50] ** 2)) + 1e-9)
    return dict(video_id=film["video_id"], has_audio=True, seconds=len(audio) / SR, film_rms=film_rms,
                labels=[model.config.id2label[i] for i in range(model.config.num_labels)], windows=out)
