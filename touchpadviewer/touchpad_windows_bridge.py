#!/usr/bin/env python3
"""
Minimal WM_POINTER-based touchpad bridge for Windows.
Creates a message-only window and listens for WM_POINTER* messages, then
writes normalized touch state to the --state JSON file so the Godot project
can read finger positions and throttle.

This implementation uses ctypes to call GetPointerTouchInfo. It is best-effort
and targets Windows 8+ (WM_POINTER available). For production use, test on
several Precision Touchpad devices and extend the structs as needed.
"""
import argparse
import ctypes
import json
import sys
import threading
import time
from ctypes import wintypes

user32 = ctypes.WinDLL('user32', use_last_error=True)

WM_POINTERUPDATE = 0x0245
WM_POINTERDOWN = 0x0246
WM_POINTERUP = 0x0247

# Basic POINT struct
class POINT(ctypes.Structure):
    _fields_ = [('x', wintypes.LONG), ('y', wintypes.LONG)]

# Minimal POINTER_INFO (partial) - sufficient to read ptPixelLocation and pointerId
class POINTER_INFO(ctypes.Structure):
    _fields_ = [
        ('pointerType', wintypes.UINT),
        ('pointerId', wintypes.UINT),
        ('frameId', wintypes.UINT),
        ('pointerFlags', wintypes.UINT),
        ('sourceDevice', wintypes.HANDLE),
        ('hwndTarget', wintypes.HWND),
        ('ptPixelLocation', POINT),
        ('ptHimetricLocation', POINT),
        ('ptPixelLocationRaw', POINT),
        ('ptHimetricLocationRaw', POINT),
        ('dwTime', wintypes.DWORD),
        ('historyCount', wintypes.UINT),
        ('inputData', wintypes.INT),
        ('dwKeyStates', wintypes.DWORD),
        ('PerformanceCount', wintypes.ULONGLONG),
        ('ButtonChangeType', wintypes.INT),
    ]

# Minimal TOUCH_INFO container (we only need pointerInfo)
class POINTER_TOUCH_INFO(ctypes.Structure):
    _fields_ = [
        ('pointerInfo', POINTER_INFO),
        ('touchFlags', wintypes.UINT),
        ('touchMask', wintypes.UINT),
        ('rcContact_left', wintypes.LONG),
        ('rcContact_top', wintypes.LONG),
        ('rcContact_right', wintypes.LONG),
        ('rcContact_bottom', wintypes.LONG),
        ('orientation', wintypes.UINT),
        ('pressure', wintypes.UINT),
    ]

# Function prototypes
GetPointerTouchInfo = user32.GetPointerTouchInfo
GetPointerTouchInfo.argtypes = [wintypes.UINT, ctypes.POINTER(POINTER_TOUCH_INFO)]
GetPointerTouchInfo.restype = wintypes.BOOL

# Helper to extract pointer id from wParam
def GET_POINTERID_WPARAM(wParam):
    return wParam & 0xffff


class WindowsTouchBridge:
    def __init__(self, state_path, debug=False):
        self.state_path = state_path
        self.debug = debug
        self.running = False
        self.slots = {}  # pointerId -> {'x': px, 'y': py}
        self.lock = threading.Lock()

    def _write_state(self):
        with self.lock:
            left = {'active': False, 'x': 0.5, 'y': 0.5}
            right = {'active': False, 'two': False, 'f1': {'x': 0.5, 'y': 0.5}, 'f2': {'x': 0.5, 'y': 0.5}, 'throttle': 0.0, 'gear': 0}
            # Classify touches: naive split by screen midpoint X
            if self.slots:
                pts = list(self.slots.values())
                # require screen metrics to normalize; use primary monitor size
                width = ctypes.windll.user32.GetSystemMetrics(0)
                height = ctypes.windll.user32.GetSystemMetrics(1)
                left_pts = [p for p in pts if p['x'] < width * 0.5]
                right_pts = [p for p in pts if p['x'] >= width * 0.5]
                if left_pts:
                    left['active'] = True
                    p = left_pts[0]
                    left['x'] = max(0.0, min(1.0, p['x'] / max(1, width)))
                    left['y'] = max(0.0, min(1.0, p['y'] / max(1, height)))
                if right_pts:
                    right['active'] = True
                    right['two'] = len(right_pts) > 1
                    p1 = right_pts[0]
                    right['f1']['x'] = max(0.0, min(1.0, (p1['x'] - width * 0.5) / max(1.0, width * 0.5)))
                    right['f1']['y'] = max(0.0, min(1.0, p1['y'] / max(1, height)))
                    if len(right_pts) > 1:
                        p2 = right_pts[1]
                        right['f2']['x'] = max(0.0, min(1.0, (p2['x'] - width * 0.5) / max(1.0, width * 0.5)))
                        right['f2']['y'] = max(0.0, min(1.0, p2['y'] / max(1, height)))
            try:
                with open(self.state_path, 'w', encoding='ascii') as f:
                    f.write(json.dumps({'left': left, 'right': right}))
            except OSError:
                pass

    def run_message_loop(self):
        # Create a message-only window to receive pointer messages
        WNDPROC = ctypes.WINFUNCTYPE(ctypes.c_long, wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM)

        @WNDPROC
        def wndproc(hwnd, msg, wParam, lParam):
            if msg in (WM_POINTERDOWN, WM_POINTERUPDATE, WM_POINTERUP):
                pid = GET_POINTERID_WPARAM(wParam)
                info = POINTER_TOUCH_INFO()
                ok = GetPointerTouchInfo(pid, ctypes.byref(info))
                if ok:
                    x = info.pointerInfo.ptPixelLocation.x
                    y = info.pointerInfo.ptPixelLocation.y
                    if msg == WM_POINTERUP:
                        with self.lock:
                            self.slots.pop(pid, None)
                    else:
                        with self.lock:
                            self.slots[pid] = {'x': x, 'y': y}
                    # write state on each update
                    self._write_state()
            return user32.DefWindowProcW(hwnd, msg, wParam, lParam)

        class_name = 'TouchpadBridgeHiddenWindow'
        wndclass = wintypes.WNDCLASS()
        wndclass.lpfnWndProc = wndproc
        wndclass.lpszClassName = class_name
        atom = user32.RegisterClassW(ctypes.byref(wndclass))
        hwnd = user32.CreateWindowExW(0, class_name, 'TouchpadBridge', 0, 0, 0, 0, 0, wintypes.HWND_MESSAGE, 0, 0, None)
        if not hwnd:
            print('Failed to create hidden window for WM_POINTER', file=sys.stderr)
            return
        self.running = True
        msg = wintypes.MSG()
        while self.running:
            bRet = user32.GetMessageW(ctypes.byref(msg), 0, 0, 0)
            if bRet == 0:
                break
            elif bRet == -1:
                break
            else:
                user32.TranslateMessage(ctypes.byref(msg))
                user32.DispatchMessageW(ctypes.byref(msg))
        user32.DestroyWindow(hwnd)

    def start(self):
        t = threading.Thread(target=self.run_message_loop, daemon=True)
        t.start()
        try:
            while True:
                time.sleep(1.0)
        except KeyboardInterrupt:
            self.running = False


def main():
    parser = argparse.ArgumentParser(description='Windows WM_POINTER touchpad bridge')
    parser.add_argument('--state', help='path to write JSON state for HUD')
    parser.add_argument('--debug', action='store_true')
    args = parser.parse_args()

    if not args.state:
        print('state path required --state', file=sys.stderr)
        return 2

    bridge = WindowsTouchBridge(args.state, debug=args.debug)
    bridge.start()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
