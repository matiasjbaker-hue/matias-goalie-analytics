"""
A small, dependency-free constant-velocity Kalman filter for 2D position
tracking. Written out explicitly (rather than pulled from a library) so
the puck-tracking math stays inspectable and tunable.

State x = [px, py, vx, vy]^T. We only ever observe position (H picks out
px, py); velocity is inferred by the filter, which is what lets the shot
detector read instantaneous speed directly off the state instead of
finite-differencing noisy raw detections.
"""

import numpy as np


class ConstantVelocityKalman2D:
    def __init__(self, process_noise_accel_var, measurement_noise_var):
        self.q = float(process_noise_accel_var)
        self.r_var = float(measurement_noise_var)
        self.x = np.zeros((4, 1))
        self.P = np.eye(4) * 1e6  # uninitialised: huge uncertainty
        self.initialised = False

    def reset(self, px, py, vx=0.0, vy=0.0, position_var=None):
        self.x = np.array([[px], [py], [vx], [vy]], dtype=float)
        pv = self.r_var if position_var is None else position_var
        self.P = np.diag([pv, pv, pv * 50.0, pv * 50.0]).astype(float)
        self.initialised = True

    def _F(self, dt):
        return np.array([
            [1, 0, dt, 0],
            [0, 1, 0, dt],
            [0, 0, 1, 0],
            [0, 0, 0, 1],
        ], dtype=float)

    def _Q(self, dt):
        # Discretised white-noise-acceleration model.
        q = self.q
        dt2, dt3, dt4 = dt * dt, dt ** 3, dt ** 4
        return q * np.array([
            [dt4 / 4, 0, dt3 / 2, 0],
            [0, dt4 / 4, 0, dt3 / 2],
            [dt3 / 2, 0, dt2, 0],
            [0, dt3 / 2, 0, dt2],
        ], dtype=float)

    def predict(self, dt):
        if not self.initialised:
            return None
        F = self._F(dt)
        self.x = F @ self.x
        self.P = F @ self.P @ F.T + self._Q(dt)
        return self.x.copy()

    def innovation(self, z):
        """Return (y, S, K) for a candidate measurement z=[px,py] without
        committing it, so callers can gate on Mahalanobis distance first."""
        H = np.array([[1, 0, 0, 0], [0, 1, 0, 0]], dtype=float)
        R = np.eye(2) * self.r_var
        z = np.array(z, dtype=float).reshape(2, 1)
        y = z - H @ self.x
        S = H @ self.P @ H.T + R
        K = self.P @ H.T @ np.linalg.inv(S)
        return y, S, K

    @staticmethod
    def mahalanobis_sq(y, S):
        return float((y.T @ np.linalg.inv(S) @ y)[0, 0])

    def update(self, z):
        H = np.array([[1, 0, 0, 0], [0, 1, 0, 0]], dtype=float)
        y, S, K = self.innovation(z)
        self.x = self.x + K @ y
        self.P = (np.eye(4) - K @ H) @ self.P

    @property
    def position(self):
        return float(self.x[0, 0]), float(self.x[1, 0])

    @property
    def velocity(self):
        return float(self.x[2, 0]), float(self.x[3, 0])

    @property
    def speed(self):
        vx, vy = self.velocity
        return float(np.hypot(vx, vy))
