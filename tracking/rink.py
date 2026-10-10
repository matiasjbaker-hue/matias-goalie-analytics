"""
Rink calibration: maps pixel coordinates in a (mostly static) camera's
frame to real-world rink coordinates in feet, via a homography computed
from a handful of known rink markings clicked once per video.

Rink coordinate system (feet):
  x: distance from the calibrated net's goal line, increasing into the
     defensive zone toward the blue line / neutral zone.
  y: lateral offset from the rink's longitudinal centerline, positive to
     one side (whichever side the user clicks first).

This matches the markings GoalieIQ's own shot map already draws (goal
line, faceoff dots/circles, crease, blue line) -- see DESIGN.md.

A homography assumes the source points are coplanar (true for anything
drawn on the ice) and the camera does not move between calibration and
use. If the camera pans/zooms mid-video, calibrate separate segments and
list them with their valid [start_s, end_s) windows.
"""

import json
from dataclasses import asdict

import numpy as np
import cv2

from config import RinkGeometry


def reference_points(geo: RinkGeometry):
    """Named rink-space points (feet) a user can click on frame, in a
    fixed, documented order. Returns an ordered dict name -> (x, y)."""
    g = geo
    return {
        "goal_post_near": (0.0, -g.goal_width_ft / 2),
        "goal_post_far": (0.0, g.goal_width_ft / 2),
        "faceoff_dot_near": (g.faceoff_dot_from_goal_line_ft, -g.faceoff_dot_from_centerline_ft),
        "faceoff_dot_far": (g.faceoff_dot_from_goal_line_ft, g.faceoff_dot_from_centerline_ft),
        "blue_line_near_board": (g.blue_line_from_goal_line_ft, -g.width_ft / 2),
        "blue_line_far_board": (g.blue_line_from_goal_line_ft, g.width_ft / 2),
    }


CALIBRATION_ORDER = [
    "goal_post_near", "goal_post_far",
    "faceoff_dot_near", "faceoff_dot_far",
    "blue_line_near_board", "blue_line_far_board",
]


class RinkCalibration:
    """One homography, valid for a time window [start_s, end_s) of a
    specific video. `side` labels which net this calibration covers
    ("near" is enough for single-end footage; set both to get a
    two-net rink for direction-to-net checks on full-ice video)."""

    def __init__(self, homography, geometry: RinkGeometry, start_s=0.0, end_s=None, side="near"):
        self.H = np.asarray(homography, dtype=float)
        self.H_inv = np.linalg.inv(self.H)
        self.geometry = geometry
        self.start_s = float(start_s)
        self.end_s = None if end_s is None else float(end_s)
        self.side = side

    def covers(self, t_s):
        if t_s < self.start_s:
            return False
        if self.end_s is not None and t_s >= self.end_s:
            return False
        return True

    def pixel_to_rink(self, px, py):
        v = self.H @ np.array([px, py, 1.0])
        v = v / v[2]
        return float(v[0]), float(v[1])

    def rink_to_pixel(self, rx, ry):
        v = self.H_inv @ np.array([rx, ry, 1.0])
        v = v / v[2]
        return float(v[0]), float(v[1])

    def goal_mouth(self):
        pts = reference_points(self.geometry)
        return pts["goal_post_near"], pts["goal_post_far"]

    def goal_mouth_center(self):
        (x1, y1), (x2, y2) = self.goal_mouth()
        return (x1 + x2) / 2.0, (y1 + y2) / 2.0

    @classmethod
    def from_clicks(cls, pixel_points, geometry: RinkGeometry, order=None, start_s=0.0, end_s=None, side="near"):
        """pixel_points: list of (px, py) in the order given by `order`
        (defaults to CALIBRATION_ORDER). Points may be dropped (None) if
        occluded, as long as >=4 remain and they aren't collinear."""
        order = order or CALIBRATION_ORDER
        ref = reference_points(geometry)
        src, dst = [], []
        for name, p in zip(order, pixel_points):
            if p is None:
                continue
            src.append(p)
            dst.append(ref[name])
        if len(src) < 4:
            raise ValueError(f"Need at least 4 calibration points, got {len(src)}.")
        src = np.array(src, dtype=float)
        dst = np.array(dst, dtype=float)
        H, _mask = cv2.findHomography(src, dst, method=cv2.RANSAC if len(src) > 4 else 0)
        if H is None:
            raise ValueError("Could not compute a homography from the given points (are they collinear?).")
        return cls(H, geometry, start_s=start_s, end_s=end_s, side=side)

    def to_dict(self):
        return {
            "homography": self.H.tolist(),
            "geometry": asdict(self.geometry),
            "start_s": self.start_s,
            "end_s": self.end_s,
            "side": self.side,
        }

    @classmethod
    def from_dict(cls, d):
        geo = RinkGeometry(**d["geometry"])
        return cls(d["homography"], geo, start_s=d.get("start_s", 0.0), end_s=d.get("end_s"), side=d.get("side", "near"))


class CalibrationSet:
    """All calibrations for one video. Picks the right one by timestamp."""

    def __init__(self, calibrations):
        self.calibrations = list(calibrations)

    def for_time(self, t_s):
        for c in self.calibrations:
            if c.covers(t_s):
                return c
        return None

    def save(self, path):
        with open(path, "w") as f:
            json.dump([c.to_dict() for c in self.calibrations], f, indent=2)

    @classmethod
    def load(cls, path):
        with open(path) as f:
            data = json.load(f)
        return cls([RinkCalibration.from_dict(d) for d in data])
