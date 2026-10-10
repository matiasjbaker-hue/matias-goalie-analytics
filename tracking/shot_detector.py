"""
Turns the puck's tracked trajectory (puck_tracker.PuckTracker.history, in
rink-feet once a RinkCalibration is active) into discrete shot events.

A release is: a local peak in puck speed that (a) exceeds
SHOT_RELEASE_SPEED_FTPS, (b) was clearly slower
(<=SHOT_PRE_RELEASE_SPEED_FTPS) shortly before -- i.e. a genuine
acceleration, not a puck that was already moving fast (a clear/pass
cruising through isn't a "release") -- and (c) is aimed at the tracked
net's mouth within SHOT_DIRECTION_TOLERANCE_DEG. The puck's Kalman
velocity state is used directly for direction and speed, rather than
finite-differencing raw positions, since that's exactly what the filter
is for.

This is intentionally scoped to ONE net at a time (whichever
RinkCalibration is active for that moment) -- see rink.py: GoalieIQ
tracks shots against one tracked goalie, not full-ice play at both ends.
"""

import math

import config


class ShotEvent:
    def __init__(self, t_s, x_ft, y_ft, speed_ftps, direction_deg, shooter_track_id, confidence, note=""):
        self.t_s = t_s
        self.x_ft = x_ft
        self.y_ft = y_ft
        self.speed_ftps = speed_ftps
        self.direction_deg = direction_deg
        self.shooter_track_id = shooter_track_id
        self.confidence = confidence
        self.note = note

    def to_dict(self):
        return {
            "t_s": round(self.t_s, 2),
            "puck_rink_ft": [round(self.x_ft, 2), round(self.y_ft, 2)],
            "speed_mph": round(self.speed_ftps * config.FTPS_TO_MPH, 1),
            "direction_deg_to_net": round(self.direction_deg, 1),
            "shooter_track_id": self.shooter_track_id,
            "confidence": round(self.confidence, 2),
            "note": self.note,
        }


def _local_maxima(speeds, radius=2):
    n = len(speeds)
    idxs = []
    for i in range(n):
        lo, hi = max(0, i - radius), min(n, i + radius + 1)
        window = speeds[lo:hi]
        if speeds[i] == max(window) and speeds[i] > 0:
            idxs.append(i)
    # collapse runs of equal-speed plateaus to their first index
    out = []
    for i in idxs:
        if out and i - out[-1] <= radius:
            continue
        out.append(i)
    return out


def _nearest_player_distance(player_tracker, calib, t_s, window_s, x_ft, y_ft):
    if player_tracker is None or calib is None:
        return None, None
    best_tid, best_d = None, None
    for tid, pts in player_tracker.track_positions.items():
        for pt_s, cx, cy in pts:
            if not (t_s - window_s <= pt_s <= t_s):
                continue
            rx, ry = calib.pixel_to_rink(cx, cy)
            d = math.hypot(rx - x_ft, ry - y_ft)
            if best_d is None or d < best_d:
                best_d, best_tid = d, tid
    return best_tid, best_d


def detect_shots(puck_history, calibration_set, player_tracker=None):
    events = []
    n = len(puck_history)
    speeds = [h["speed"] if h["x"] is not None else 0.0 for h in puck_history]
    peak_idxs = _local_maxima(speeds, radius=2)

    # Estimate the real frame spacing so the pre-release lookback covers
    # config.SHOT_PRE_RELEASE_WINDOW_S regardless of the video's fps
    # (a fixed frame-count bound would under-cover high-fps footage).
    if n > 1:
        dt_est = (puck_history[-1]["t"] - puck_history[0]["t"]) / (n - 1)
    else:
        dt_est = 1.0 / 30.0
    lookback_frames = max(5, int(config.SHOT_PRE_RELEASE_WINDOW_S / max(dt_est, 1e-6)) + 5)

    last_event_t = -1e9
    for i in peak_idxs:
        h = puck_history[i]
        if h["x"] is None or h["speed"] < config.SHOT_RELEASE_SPEED_FTPS:
            continue

        # Was it clearly slower just before? (a real acceleration, not a
        # cruising pass/clear that happens to exceed the threshold). Also
        # pin down WHERE the rise actually started: the peak index `i`
        # can sit a few frames after the true release (Kalman convergence
        # lag, especially right after a reacquisition reseed), by which
        # time a fast puck has already travelled many feet downstream.
        # Using the peak's own position for shot location/shooter
        # attribution would then misplace the shot and miss the shooter
        # entirely, so location/attribution use the last frame that was
        # still "slow" -- the best available pre-rise position -- while
        # speed/direction (which need a settled velocity estimate) still
        # use the peak. Deliberately NOT the first "fast" frame after it:
        # on a reacquisition reseed that frame's position jumps straight
        # to wherever the puck actually is now, which is itself already
        # downstream, not a smooth continuation of the slow phase.
        window_start = h["t"] - config.SHOT_PRE_RELEASE_WINDOW_S
        prior = [j for j in range(max(0, i - lookback_frames), i)
                 if puck_history[j]["t"] >= window_start and puck_history[j]["x"] is not None]
        slow_prior = [j for j in prior if puck_history[j]["speed"] <= config.SHOT_PRE_RELEASE_SPEED_FTPS]
        if not slow_prior:
            continue
        origin_idx = max(slow_prior)
        ho = puck_history[origin_idx]
        if ho["x"] is None:
            continue

        if ho["t"] - last_event_t < config.SHOT_COOLDOWN_S:
            continue

        calib = calibration_set.for_time(ho["t"]) if calibration_set else None
        if calib is None:
            continue  # no real-world geometry here; can't judge direction

        gx, gy = calib.goal_mouth_center()
        to_net = (gx - ho["x"], gy - ho["y"])
        to_net_norm = math.hypot(*to_net)
        if to_net_norm < 1e-6:
            continue
        vel_norm = math.hypot(h["vx"], h["vy"])
        if vel_norm < 1e-6:
            continue
        cos_angle = (h["vx"] * to_net[0] + h["vy"] * to_net[1]) / (vel_norm * to_net_norm)
        angle_deg = math.degrees(math.acos(max(-1.0, min(1.0, cos_angle))))
        if angle_deg > config.SHOT_DIRECTION_TOLERANCE_DEG:
            continue

        shooter_tid, shooter_d = _nearest_player_distance(
            player_tracker, calib, ho["t"], config.SHOT_STICK_WINDOW_S, ho["x"], ho["y"],
        )
        shooter_confirmed = shooter_d is not None and shooter_d <= config.SHOT_STICK_RANGE_FT

        confidence = 0.5
        confidence += 0.25 * max(0.0, (config.SHOT_DIRECTION_TOLERANCE_DEG - angle_deg) / config.SHOT_DIRECTION_TOLERANCE_DEG)
        confidence += 0.15 if shooter_confirmed else -0.15
        confidence += 0.1 if h["status"] == "tracked" else -0.1
        confidence = max(0.05, min(0.99, confidence))

        note = "" if shooter_confirmed else "no tracked player confirmed near the puck at release"
        events.append(ShotEvent(
            ho["t"], ho["x"], ho["y"], h["speed"], angle_deg,
            shooter_tid if shooter_confirmed else None, confidence, note,
        ))
        last_event_t = ho["t"]

    return events
