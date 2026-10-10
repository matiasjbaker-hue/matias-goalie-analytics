"""
Player (and goalie) tracking: Ultralytics YOLO's built-in ByteTrack
tracker, restricted to the "person" class, run frame-by-frame so it can
be interleaved with puck tracking on the same frame read.
"""

from collections import defaultdict

import config


class PlayerTracker:
    def __init__(self, weights="yolov8n.pt", device="cpu", conf=0.25, tracker_cfg="bytetrack.yaml"):
        from ultralytics import YOLO
        self.model = YOLO(weights)
        self.device = device
        self.conf = conf
        self.tracker_cfg = tracker_cfg
        self.track_positions = defaultdict(list)  # track_id -> [(t, cx, cy)]

    def step(self, frame_bgr, t_s):
        results = self.model.track(
            frame_bgr, device=self.device, conf=self.conf, classes=[config.COCO_PERSON_CLASS],
            tracker=self.tracker_cfg, persist=True, verbose=False,
        )
        out = []
        r = results[0]
        if r.boxes is not None and r.boxes.id is not None:
            ids = r.boxes.id.int().tolist()
            xyxy = r.boxes.xyxy.tolist()
            confs = r.boxes.conf.tolist()
            for tid, (x1, y1, x2, y2), c in zip(ids, xyxy, confs):
                cx, cy = (x1 + x2) / 2.0, y2  # feet-of-bbox: better proxy for ice contact point than center
                out.append({"track_id": tid, "bbox": [x1, y1, x2, y2], "conf": c, "cx": cx, "cy": cy})
                self.track_positions[tid].append((t_s, cx, cy))
        return out

    def identify_goalies(self, calibration_set, crease_radius_ft=9.0):
        """Heuristic: for each net side seen, the track that spends the
        largest share of its time within crease_radius_ft of that net's
        goal-mouth center is that net's goalie. Returns {track_id: side}."""
        if not self.track_positions:
            return {}
        near_counts = defaultdict(lambda: defaultdict(int))
        total_counts = defaultdict(int)
        for tid, pts in self.track_positions.items():
            for t_s, cx, cy in pts:
                calib = calibration_set.for_time(t_s) if calibration_set else None
                if calib is None:
                    continue
                rx, ry = calib.pixel_to_rink(cx, cy)
                gx, gy = calib.goal_mouth_center()
                total_counts[tid] += 1
                if ((rx - gx) ** 2 + (ry - gy) ** 2) ** 0.5 <= crease_radius_ft:
                    near_counts[tid][calib.side] += 1

        goalies = {}
        best_by_side = {}
        for tid, by_side in near_counts.items():
            if total_counts[tid] == 0:
                continue
            for side, n in by_side.items():
                frac = n / total_counts[tid]
                if frac < 0.3:  # must actually park in the crease most of the time
                    continue
                if side not in best_by_side or frac > best_by_side[side][1]:
                    best_by_side[side] = (tid, frac)
        for side, (tid, _frac) in best_by_side.items():
            goalies[tid] = side
        return goalies
