"""
CLI entrypoint.

Examples:
    # 1) Calibrate once (see rink_calibrate.py --help for the click order):
    python rink_calibrate.py --video game.mp4 --t 12.0 --out game_calibration.json

    # 2) Track players + puck, detect shots, and write an annotated video:
    python main.py --video game.mp4 --calibration game_calibration.json \
        --out game_results.json --annotate game_annotated.mp4

    # Quick look without calibration (puck track + boxes only, no shot math):
    python main.py --video game.mp4 --out quick.json --annotate quick.mp4 --stride 2
"""

import argparse
import sys

from pipeline import run


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", required=True, help="Path to the game video.")
    ap.add_argument("--out", required=True, help="Where to write the JSON report.")
    ap.add_argument("--calibration", default=None, help="Calibration JSON from rink_calibrate.py.")
    ap.add_argument("--annotate", default=None, help="Optional path to write an annotated .mp4.")
    ap.add_argument("--player-weights", default="yolov8n.pt", help="Ultralytics weights for player detection (auto-downloads if not local).")
    ap.add_argument("--puck-weights", default=None, help="Optional custom-trained puck YOLO weights.")
    ap.add_argument("--puck-weights-coco-ball", action="store_true",
                     help="Treat --puck-weights as a stock COCO model and use its 'sports ball' class as a weak prior, instead of a custom puck class.")
    ap.add_argument("--device", default="cpu", help="'cpu', 'cuda' (NVIDIA only), or a specific device string Ultralytics accepts.")
    ap.add_argument("--start", type=float, default=0.0, help="Start time (s) to process from.")
    ap.add_argument("--end", type=float, default=None, help="End time (s) to stop at.")
    ap.add_argument("--stride", type=int, default=1, help="Process every Nth frame (speeds things up on CPU; keep at 1 for the most accurate puck tracking).")
    ap.add_argument("--show", action="store_true", help="Show a live preview window while processing.")
    args = ap.parse_args()

    run(
        video_path=args.video,
        out_json=args.out,
        calibration_path=args.calibration,
        annotate_path=args.annotate,
        player_weights=args.player_weights,
        puck_weights=args.puck_weights,
        puck_weights_is_custom=not args.puck_weights_coco_ball,
        device=args.device,
        start_s=args.start,
        end_s=args.end,
        stride=args.stride,
        show=args.show,
    )


if __name__ == "__main__":
    sys.exit(main())
