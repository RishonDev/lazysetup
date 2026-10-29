#!/usr/bin/env python3
"""camfix: face-aware webcam enhancer -> v4l2loopback virtual camera.

Linux stand-in for the Windows camera pipeline (Platform DMFT face-based
exposure + Studio Effects portrait light). Reads the real webcam only while
some app has the virtual camera open, so the camera LED stays off otherwise.
"""
import argparse
import os
import subprocess
import sys
import time

import cv2
import numpy as np

CASCADE = "/usr/share/opencv5/haarcascades/haarcascade_frontalface_default.xml"


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--src", default="/dev/video0")
    p.add_argument("--dst", default="/dev/video10")
    p.add_argument("--width", type=int, default=1280)
    p.add_argument("--height", type=int, default=720)
    p.add_argument("--fps", type=int, default=30)
    p.add_argument("--target", type=float, default=135, help="face brightness target (0-255)")
    p.add_argument("--light", type=float, default=0.25, help="portrait light strength (0 = off)")
    p.add_argument("--contrast", type=float, default=1.6, help="local contrast (CLAHE clip, 0 = off)")
    p.add_argument("--max-boost", type=float, default=2.2, help="cap on exposure boost")
    p.add_argument("--no-bt709", dest="bt709", action="store_false", help="skip BT.709 colour fix")
    p.add_argument("--always-on", action="store_true", help="keep the camera open even with no viewers")
    p.add_argument("--test", type=int, default=0, help="process N frames, print stats, write test.jpg, exit")
    return p.parse_args()


def bt709_fix():
    """BGR->BGR matrix undoing a BT.601 decode of BT.709-encoded MJPEG.

    The Windows Realtek camera extension (RtExtAsus.inf) tags this camera with
    FSColorInfoOverride=0x01050102 (BT.709, full range); libjpeg decodes as BT.601.
    """
    kr, kb = 0.299, 0.114
    to601 = np.array([[kr, 1 - kr - kb, kb],
                      [-kr / 1.772, -(1 - kr - kb) / 1.772, 0.5],
                      [0.5, -(1 - kr - kb) / 1.402, -kb / 1.402]])  # RGB -> Y Cb Cr
    kr, kb = 0.2126, 0.0722
    kg = 1 - kr - kb
    from709 = np.array([[1, 0, 2 * (1 - kr)],
                        [1, -2 * (1 - kb) * kb / kg, -2 * (1 - kr) * kr / kg],
                        [1, 2 * (1 - kb), 0]])  # Y Cb Cr -> RGB
    m = from709 @ to601
    return m[::-1, ::-1].astype(np.float32)  # RGB order -> BGR order


class Enhancer:
    def __init__(self, a):
        self.a = a
        self.det = cv2.CascadeClassifier(CASCADE)
        self.face = None          # smoothed (cx, cy, w, h) in pixels
        self.face_age = 999       # frames since last detection
        self.gamma = 1.0          # smoothed tone curve exponent
        self.n = 0
        self.clahe = cv2.createCLAHE(clipLimit=a.contrast, tileGridSize=(8, 8)) if a.contrast > 0 else None
        self.cm = bt709_fix() if a.bt709 else None
        self.xs = np.arange(a.width, dtype=np.float32)
        self.ys = np.arange(a.height, dtype=np.float32)

    def detect(self, gray):
        s = 4
        small = cv2.resize(gray, (gray.shape[1] // s, gray.shape[0] // s))
        small = cv2.equalizeHist(small)  # helps find dark faces
        faces = self.det.detectMultiScale(small, 1.15, 4, minSize=(20, 20))
        if len(faces) == 0:
            self.face_age += 6
            return
        x, y, w, h = max(faces, key=lambda f: f[2] * f[3]) * s
        new = np.array([x + w / 2, y + h / 2, w, h], np.float32)
        self.face = new if self.face is None or self.face_age > 60 else 0.6 * self.face + 0.4 * new
        self.face_age = 0

    def metering_mask(self, shape):
        h, w = shape
        if self.face is not None and self.face_age < 90:
            cx, cy, fw, fh = self.face
            # Meter the central part of the face (skip hair/background at edges).
            x0, x1 = int(cx - fw * 0.3), int(cx + fw * 0.3)
            y0, y1 = int(cy - fh * 0.3), int(cy + fh * 0.35)
        else:
            # No face: center-weighted like a normal camera.
            x0, x1, y0, y1 = w // 3, 2 * w // 3, h // 4, 3 * h // 4
        return max(x0, 0), min(x1, w), max(y0, 0), min(y1, h)

    def process(self, frame):
        a = self.a
        self.n += 1
        if self.cm is not None:
            frame = cv2.transform(frame, self.cm)
        ycc = cv2.cvtColor(frame, cv2.COLOR_BGR2YCrCb)
        y = ycc[:, :, 0]
        if self.n % 5 == 1:
            self.detect(y)
        else:
            self.face_age += 1

        # Face-based exposure: pick a gamma that maps metered brightness to target.
        x0, x1, y0, y1 = self.metering_mask(y.shape)
        m = float(np.mean(y[y0:y1, x0:x1])) if x1 > x0 and y1 > y0 else 128.0
        m = min(max(m, 8.0), 250.0)
        want = np.log(a.target / 255.0) / np.log(m / 255.0)
        want = min(max(want, 1.0 / a.max_boost), 1.6)
        self.gamma += (want - self.gamma) * 0.08  # smooth so it doesn't pump
        lut = np.clip(255.0 * (np.arange(256) / 255.0) ** self.gamma, 0, 255).astype(np.uint8)
        y = cv2.LUT(y, lut)

        if self.clahe is not None:
            y = cv2.addWeighted(self.clahe.apply(y), 0.5, y, 0.5, 0)

        # Portrait light: soft gaussian fill centred on the face.
        if a.light > 0 and self.face is not None and self.face_age < 90:
            cx, cy, fw, fh = self.face
            sx, sy = fw * 1.1, fh * 1.4
            # Separable gaussian: outer product of two 1-D curves is far cheaper than a 2-D exp.
            fade = max(0.0, 1.0 - self.face_age / 90.0)
            gx = np.exp(-((self.xs - cx) / sx) ** 2 / 2)
            gy = np.exp(-((self.ys - cy - fh * 0.1) / sy) ** 2 / 2) * (a.light * fade)
            gain = np.outer(gy, gx) + 1.0
            y = cv2.multiply(y, gain, dtype=cv2.CV_8U)

        ycc[:, :, 0] = y
        return cv2.cvtColor(ycc, cv2.COLOR_YCrCb2BGR), m


def open_camera(a):
    cap = cv2.VideoCapture(a.src, cv2.CAP_V4L2)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, a.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, a.height)
    cap.set(cv2.CAP_PROP_FPS, a.fps)
    if not cap.isOpened():
        raise RuntimeError(f"cannot open {a.src}")
    return cap


def open_sink(a):
    cmd = ["ffmpeg", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgr24",
           "-s", f"{a.width}x{a.height}", "-r", str(a.fps), "-i", "-",
           "-f", "v4l2", "-pix_fmt", "yuyv422", a.dst]
    return subprocess.Popen(cmd, stdin=subprocess.PIPE)


def viewers(dst, exclude):
    """PIDs (other than ours) that have the virtual camera open."""
    real = os.path.realpath(dst)
    found = set()
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or int(pid) in exclude:
            continue
        fd_dir = f"/proc/{pid}/fd"
        try:
            for fd in os.listdir(fd_dir):
                if os.readlink(f"{fd_dir}/{fd}") == real:
                    found.add(int(pid))
                    break
        except OSError:
            continue
    return found


def run_test(a):
    cap = open_camera(a)
    enh = Enhancer(a)
    t0 = time.time()
    for _ in range(a.test):
        ok, frame = cap.read()
        if not ok:
            sys.exit("camera read failed")
        out, m = enh.process(frame)
    dt = time.time() - t0
    cv2.imwrite("test_in.jpg", frame)
    cv2.imwrite("test.jpg", out)
    print(f"fps={a.test / dt:.1f} metered_in={m:.1f} gamma={enh.gamma:.2f} face={'yes' if enh.face_age < 90 else 'no'}")


def main():
    a = parse_args()
    if a.test:
        return run_test(a)

    sink = open_sink(a)
    exclude = {os.getpid(), sink.pid}
    idle = np.zeros((a.height, a.width, 3), np.uint8)
    cap, enh, last_check, active = None, None, 0.0, a.always_on
    try:
        while True:
            now = time.time()
            if not a.always_on and now - last_check > 1.0:
                last_check = now
                active = bool(viewers(a.dst, exclude))
            if active and cap is None:
                cap, enh = open_camera(a), Enhancer(a)
            elif not active and cap is not None:
                cap.release()
                cap = None
            if cap is None:
                # Keep the loopback alive (so apps list it) without touching the camera.
                sink.stdin.write(idle.tobytes())
                time.sleep(1.0 / 5)
                continue
            ok, frame = cap.read()
            if not ok:
                cap.release()
                cap = None
                time.sleep(0.5)
                continue
            out, _ = enh.process(frame)
            sink.stdin.write(out.tobytes())
    except (KeyboardInterrupt, BrokenPipeError):
        pass
    finally:
        if cap is not None:
            cap.release()
        sink.terminate()


if __name__ == "__main__":
    main()
