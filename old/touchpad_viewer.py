#!/usr/bin/env python3
"""
Touchpad MT visualizer (Arch Linux)
- Shows live multi-finger slots + coordinates
- Draws touch points on a canvas normalized to touchpad coordinate range
- Uses evdev MT protocol: ABS_MT_SLOT, ABS_MT_TRACKING_ID, ABS_MT_POSITION_X/Y, etc.

Usage:
  sudo ./touchpad_viewer.py /dev/input/eventXX
"""

import sys
import time
from dataclasses import dataclass, field
from typing import Dict, Optional, Tuple

from evdev import InputDevice, categorize, ecodes

from PyQt6.QtCore import Qt, QTimer, QRectF
from PyQt6.QtGui import QPainter, QPen, QFont
from PyQt6.QtWidgets import (
    QApplication,
    QWidget,
    QVBoxLayout,
    QHBoxLayout,
    QLabel,
    QFrame,
)

# ---------- Data model ----------

@dataclass
class Finger:
    tracking_id: Optional[int] = None
    x: Optional[int] = None
    y: Optional[int] = None
    pressure: Optional[int] = None
    touch_major: Optional[int] = None
    touch_minor: Optional[int] = None
    last_seen: float = field(default_factory=time.time)

    def is_active(self) -> bool:
        return self.tracking_id is not None and self.tracking_id != -1

# ---------- GUI widgets ----------

class TouchCanvas(QWidget):
    def __init__(self):
        super().__init__()
        self.setMinimumHeight(360)
        self.fingers: Dict[int, Finger] = {}
        self.axis_range = None  # (min_x, max_x, min_y, max_y)

    def set_state(self, fingers: Dict[int, Finger], axis_range: Tuple[int, int, int, int]):
        self.fingers = fingers
        self.axis_range = axis_range
        self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        # background
        painter.fillRect(self.rect(), self.palette().window())

        # draw "touchpad area" border
        pad_rect = self.rect().adjusted(12, 12, -12, -12)
        painter.setPen(QPen(self.palette().text().color(), 2))
        painter.drawRoundedRect(QRectF(pad_rect), 12.0, 12.0)

        if not self.axis_range:
            painter.setFont(QFont("Sans", 11))
            painter.drawText(pad_rect, Qt.AlignmentFlag.AlignCenter, "No axis info yet…")
            return

        min_x, max_x, min_y, max_y = self.axis_range
        span_x = max(1, max_x - min_x)
        span_y = max(1, max_y - min_y)

        # helper for mapping device coords -> canvas coords
        def map_xy(x, y):
            nx = (x - min_x) / span_x
            ny = (y - min_y) / span_y
            cx = pad_rect.left() + nx * pad_rect.width()
            cy = pad_rect.top() + ny * pad_rect.height()
            return cx, cy

        # draw active fingers
        now = time.time()
        for slot, f in sorted(self.fingers.items()):
            if not f.is_active() or f.x is None or f.y is None:
                continue

            cx, cy = map_xy(f.x, f.y)

            # size hint: touch_major/minor if available, else default
            major = f.touch_major or 22
            minor = f.touch_minor or 18

            # scale ellipse size to canvas in a reasonable way
            # (these MT units vary by device; we just keep it visually useful)
            ellipse_w = max(10, min(80, int(major * 2)))
            ellipse_h = max(10, min(80, int(minor * 2)))

            # fade slightly if not seen very recently
            age = now - f.last_seen
            alpha = 255 if age < 0.2 else max(80, int(255 * (0.6 / max(age, 0.6))))

            pen = QPen(self.palette().highlight().color(), 3)

            c = pen.color()
            c.setAlpha(alpha)
            pen.setColor(c)

            painter.setPen(pen)

            painter.drawEllipse(
                QRectF(cx - ellipse_w / 2, cy - ellipse_h / 2, ellipse_w, ellipse_h)
            )

            # label slot + tracking id
            painter.setFont(QFont("Sans", 10))
            label = f"slot {slot}  id {f.tracking_id}"
            painter.drawText(int(cx + 10), int(cy - 10), label)

        painter.end()


class TouchpadViewer(QWidget):
    def __init__(self, dev: InputDevice):
        super().__init__()
        self.dev = dev
        self.setWindowTitle(f"Touchpad Visualizer - {dev.name}")

        # MT state
        self.current_slot = 0
        self.fingers: Dict[int, Finger] = {i: Finger() for i in range(16)}  # up to 16 slots
        self.axis_range = self._get_axis_ranges()

        # Layout
        root = QVBoxLayout()
        self.setLayout(root)

        header = QLabel(f"<b>Device:</b> {dev.name}  <b>Path:</b> {dev.path}")
        header.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        root.addWidget(header)

        self.axis_label = QLabel(self._axis_text())
        self.axis_label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        root.addWidget(self.axis_label)

        self.canvas = TouchCanvas()
        root.addWidget(self.canvas)

        # readout box
        box = QFrame()
        box.setFrameShape(QFrame.Shape.StyledPanel)
        box_layout = QVBoxLayout()
        box.setLayout(box_layout)
        root.addWidget(box)

        self.readout = QLabel()
        self.readout.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.readout.setFont(QFont("Monospace"))
        box_layout.addWidget(self.readout)

        self.status = QLabel("Reading events… (close window to stop)")
        root.addWidget(self.status)

        # Polling timer (non-blocking)
        self.timer = QTimer(self)
        self.timer.timeout.connect(self._pump_events)
        self.timer.start(10)

        # Initial paint
        self._refresh_ui()

    def _get_axis_ranges(self) -> Tuple[int, int, int, int]:
        # Defaults if device doesn't report (rare)
        min_x, max_x, min_y, max_y = 0, 1000, 0, 1000
        caps = self.dev.capabilities(absinfo=True)

        abs_caps = dict(caps.get(ecodes.EV_ABS, []))
        # abs_caps maps code -> AbsInfo sometimes; but evdev returns list of tuples (code, AbsInfo)
        # So normalize:
        if isinstance(caps.get(ecodes.EV_ABS, []), list):
            # It is list of (code, AbsInfo)
            for code, info in caps.get(ecodes.EV_ABS, []):
                if code == ecodes.ABS_MT_POSITION_X:
                    min_x, max_x = info.min, info.max
                elif code == ecodes.ABS_MT_POSITION_Y:
                    min_y, max_y = info.min, info.max

        return (min_x, max_x, min_y, max_y)

    def _axis_text(self) -> str:
        min_x, max_x, min_y, max_y = self.axis_range
        return f"<b>Axis range</b> X: {min_x}..{max_x}    Y: {min_y}..{max_y}"

    def _pump_events(self):
        # Read all pending events without blocking
        try:
            for ev in self.dev.read():
                if ev.type != ecodes.EV_ABS:
                    continue
                self._handle_abs(ev.code, ev.value)
        except BlockingIOError:
            pass
        except OSError as e:
            self.status.setText(f"Device read error: {e}")
            self.timer.stop()
            return

        self._refresh_ui()

    def _handle_abs(self, code: int, value: int):
        now = time.time()

        if code == ecodes.ABS_MT_SLOT:
            self.current_slot = int(value)
            if self.current_slot not in self.fingers:
                self.fingers[self.current_slot] = Finger()
            return

        f = self.fingers.setdefault(self.current_slot, Finger())
        f.last_seen = now

        if code == ecodes.ABS_MT_TRACKING_ID:
            # -1 means finger lifted in this slot
            f.tracking_id = int(value)
            if f.tracking_id == -1:
                # clear associated data for nicer display
                f.x = f.y = f.pressure = f.touch_major = f.touch_minor = None
            return

        if code == ecodes.ABS_MT_POSITION_X:
            f.x = int(value)
        elif code == ecodes.ABS_MT_POSITION_Y:
            f.y = int(value)
        elif code == ecodes.ABS_MT_PRESSURE:
            f.pressure = int(value)
        elif code == ecodes.ABS_MT_TOUCH_MAJOR:
            f.touch_major = int(value)
        elif code == ecodes.ABS_MT_TOUCH_MINOR:
            f.touch_minor = int(value)

    def _refresh_ui(self):
        # Build text readout of active fingers
        lines = []
        for slot in sorted(self.fingers.keys()):
            f = self.fingers[slot]
            if not f.is_active():
                continue
            lines.append(
                f"slot {slot:2d}  id {f.tracking_id:5d}  x {str(f.x):>6}  y {str(f.y):>6}"
                f"  p {str(f.pressure):>4}  major {str(f.touch_major):>4}  minor {str(f.touch_minor):>4}"
            )

        if not lines:
            lines = ["(no active touches)"]

        self.readout.setText("\n".join(lines))
        self.canvas.set_state(self.fingers, self.axis_range)


def main():
    if len(sys.argv) != 2:
        print("Usage: sudo ./touchpad_viewer.py /dev/input/eventXX")
        sys.exit(2)

    path = sys.argv[1]
    dev = InputDevice(path)
    dev.grab()  # exclusive grab so other software won't swallow events (optional but useful)

    app = QApplication(sys.argv)
    w = TouchpadViewer(dev)
    w.resize(900, 700)
    w.show()

    code = app.exec()

    try:
        dev.ungrab()
    except Exception:
        pass
    sys.exit(code)


if __name__ == "__main__":
    main()
