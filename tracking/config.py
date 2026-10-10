"""
Tunable constants for the local puck/player tracking pipeline.

Rink dimensions below are the commonly-cited NHL numbers. They are NOT
guaranteed exact for your rink -- measure against your rink's official
diagram (or the rink's own posted specs) if you need precise real-world
distances. Everything here is overridable; nothing downstream hardcodes
these values, they only flow through RinkGeometry.
"""

from dataclasses import dataclass


@dataclass
class RinkGeometry:
    # Overall sheet, in feet. NHL = 200x85. Olympic/international = 200x100.
    length_ft: float = 200.0
    width_ft: float = 85.0

    # Distance from the end boards to the goal line.
    goal_line_from_boards_ft: float = 11.0

    # Distance from the goal line to the nearest blue line.
    # (Commonly cited as blue line 75ft from the end boards -> 64ft from
    # the goal line. VERIFY against your rink if shot speed/location
    # accuracy matters to you.)
    blue_line_from_goal_line_ft: float = 64.0

    # End-zone faceoff dots: distance from the goal line, and lateral
    # distance from the rink's longitudinal centerline.
    faceoff_dot_from_goal_line_ft: float = 20.0
    faceoff_dot_from_centerline_ft: float = 22.0
    faceoff_circle_radius_ft: float = 15.0

    # Goal mouth (regulation NHL opening width).
    goal_width_ft: float = 6.0

    # Goal crease, modelled as a simple rectangle for calibration/overlay
    # purposes (real creases have rounded front corners).
    crease_width_ft: float = 8.0
    crease_depth_ft: float = 4.5


# ---- Puck motion-candidate detector (classical CV) ----

# Candidate blob area, as a fraction of frame area (width*height). A puck
# a few pixels across in a wide rink shot is tiny; these bounds are loose
# on purpose and rely on the Kalman gate + darkness check to reject junk.
PUCK_MIN_AREA_FRAC = 0.0000015
PUCK_MAX_AREA_FRAC = 0.0025

# Motion blur stretches a round puck into an ellipse/streak; allow it.
PUCK_MAX_ASPECT_RATIO = 5.0

# A puck reads dark against bright ice. Mean grayscale level (0-255)
# under a candidate's mask must be below this to be considered.
PUCK_MAX_MEAN_GRAY = 90

# Background subtractor (MOG2) parameters.
BG_HISTORY = 200
BG_VAR_THRESHOLD = 16
BG_LEARNING_RATE = -1  # let OpenCV pick based on history

# Weak prior: COCO class 32 is "sports ball". Pretrained YOLO occasionally
# fires on the puck; treat it as a candidate, not ground truth.
COCO_SPORTS_BALL_CLASS = 32
COCO_PERSON_CLASS = 0

# ---- Kalman filter (puck) ----

# Process noise: variance of the (unmodelled) acceleration, in
# unit^2/s^4 where unit is feet if calibrated, else pixels. Deliberately
# large -- a slap shot is a huge, real acceleration event; the filter
# should bend to it quickly rather than smooth it away.
PUCK_PROCESS_NOISE_ACCEL_VAR = 4000.0

# Measurement noise: variance of a single detection's position, unit^2.
PUCK_MEASUREMENT_NOISE_VAR = 9.0

# Mahalanobis-distance^2 gate for associating a candidate to the predicted
# puck state (chi-square, 2 dof, ~99% => 9.21).
PUCK_GATE_CHI2 = 9.21

# Frames the tracker will coast (predict with no measurement) before the
# track is considered lost and must be reseeded.
PUCK_MAX_COAST_FRAMES = 45

# Consecutive frames where candidates exist but none fall inside the
# Mahalanobis gate (as opposed to no candidates at all, a real
# occlusion/blur) before the tracker gives up on the constant-velocity
# prediction and reseeds onto the best candidate immediately. This is
# what lets a genuine, sudden shot be picked up fast instead of being
# rejected as "doesn't match the model" for up to PUCK_MAX_COAST_FRAMES.
PUCK_REACQUIRE_AFTER_MISSES = 2

# ---- Shot detection ----

# A release must exceed this speed (ft/s). ~36.7 ft/s = 25 mph; tune to
# your level of play (youth/junior shots run slower than NHL).
SHOT_RELEASE_SPEED_FTPS = 36.7

# ...and the puck must have been below this speed shortly before, so a
# sustained fast pass/clear isn't mistaken for a release.
SHOT_PRE_RELEASE_SPEED_FTPS = 22.0

# How far back (seconds) to look for the "was slow" condition above.
SHOT_PRE_RELEASE_WINDOW_S = 0.35

# Angle (degrees) between release velocity and the vector to the target
# net's mouth center, within which the shot counts as "at the net".
SHOT_DIRECTION_TOLERANCE_DEG = 40.0

# A player must have been within this many feet of the puck in the window
# just before release for the puck to be attributed to them as a shooter.
SHOT_STICK_RANGE_FT = 6.0
SHOT_STICK_WINDOW_S = 0.25

# Minimum time between two separate shot events (keeps a single release
# from being reported multiple times as speed oscillates near threshold).
SHOT_COOLDOWN_S = 0.75

FTPS_TO_MPH = 0.681818
