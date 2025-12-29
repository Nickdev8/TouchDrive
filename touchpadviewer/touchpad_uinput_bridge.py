#!/usr/bin/env python3
import argparse
import os
import sys
from evdev import AbsInfo, InputDevice, UInput, ecodes, list_devices

# Minimal Linux multitouch-to-uinput bridge for Godot.
# Reads MT protocol B slots from a touchpad device and emits a virtual touchscreen.

def read_screen_size():
    # Prefer framebuffer virtual size if available ("width,height").
    try:
        with open("/sys/class/graphics/fb0/virtual_size", "r", encoding="ascii") as f:
            w_str, h_str = f.read().strip().split(",")
            return int(w_str), int(h_str)
    except (OSError, ValueError):
        return None


def scale(value, in_min, in_max, out_max):
    if in_max == in_min:
        return 0
    # Clamp then scale to [0, out_max-1].
    v = max(in_min, min(in_max, value))
    return int((v - in_min) * (out_max - 1) / (in_max - in_min))

def is_mt_device(dev):
    caps = dev.capabilities().get(ecodes.EV_ABS, [])
    abs_codes = {c if isinstance(c, int) else c[0] for c in caps}
    return (
        ecodes.ABS_MT_SLOT in abs_codes
        and ecodes.ABS_MT_POSITION_X in abs_codes
        and ecodes.ABS_MT_POSITION_Y in abs_codes
    )

def find_touchpad_device(name_hint=None):
    candidates = []
    for path in list_devices():
        dev = InputDevice(path)
        if not is_mt_device(dev):
            continue
        candidates.append(dev)

    if not candidates:
        return None

    if name_hint:
        hint = name_hint.lower()
        for dev in candidates:
            if hint in dev.name.lower():
                return dev

    # Prefer devices whose names look like touchpads.
    for dev in candidates:
        n = dev.name.lower()
        if "touchpad" in n or "trackpad" in n:
            return dev

    return candidates[0]


def main():
    parser = argparse.ArgumentParser(description="Touchpad MT -> virtual touchscreen bridge")
    parser.add_argument("device", nargs="?", help="/dev/input/eventX for the touchpad")
    parser.add_argument("--auto", action="store_true", help="auto-detect a touchpad device")
    parser.add_argument("--name", help="name substring to match for auto-detect")
    parser.add_argument("--screen", help="screen size WxH, e.g. 1920x1080")
    args = parser.parse_args()

    dev = None
    if args.device:
        dev = InputDevice(args.device)
    else:
        if not args.auto and not args.name:
            parser.error("provide a device path or use --auto/--name")
        dev = find_touchpad_device(args.name)
        if not dev:
            print("No multitouch touchpad device found.", file=sys.stderr)
            return 1
        print(f"Using device: {dev.path} ({dev.name})")

    if args.screen:
        try:
            screen_w, screen_h = [int(x) for x in args.screen.lower().split("x")]
        except ValueError:
            print("Invalid --screen format, expected WxH", file=sys.stderr)
            return 1
    else:
        size = read_screen_size()
        if not size:
            print("Could not determine screen size; pass --screen WxH", file=sys.stderr)
            return 1
        screen_w, screen_h = size

    abs_x = dev.absinfo(ecodes.ABS_MT_POSITION_X)
    abs_y = dev.absinfo(ecodes.ABS_MT_POSITION_Y)
    abs_slot = dev.absinfo(ecodes.ABS_MT_SLOT)

    # Use the device's TRACKING_ID range; -1 is still allowed to signal release.
    abs_tracking = dev.absinfo(ecodes.ABS_MT_TRACKING_ID)
    tracking_min = abs_tracking.min
    tracking_max = abs_tracking.max

    # Virtual touchscreen capabilities (MT protocol B + legacy ABS_X/Y).
    capabilities = {
        ecodes.EV_ABS: [
            (ecodes.ABS_MT_SLOT, AbsInfo(abs_slot.value, abs_slot.min, abs_slot.max, 0, 0, abs_slot.resolution)),
            (ecodes.ABS_MT_POSITION_X, AbsInfo(0, 0, screen_w - 1, 0, 0, abs_x.resolution)),
            (ecodes.ABS_MT_POSITION_Y, AbsInfo(0, 0, screen_h - 1, 0, 0, abs_y.resolution)),
            (ecodes.ABS_MT_TRACKING_ID, AbsInfo(abs_tracking.value, tracking_min, tracking_max, 0, 0, abs_tracking.resolution)),
            (ecodes.ABS_X, AbsInfo(0, 0, screen_w - 1, 0, 0, abs_x.resolution)),
            (ecodes.ABS_Y, AbsInfo(0, 0, screen_h - 1, 0, 0, abs_y.resolution)),
        ],
        ecodes.EV_KEY: [ecodes.BTN_TOUCH, ecodes.BTN_TOOL_FINGER],
    }

    ui = UInput(capabilities, name="touchpad-virtual-touchscreen", bustype=dev.info.bustype)

    current_slot = 0
    active_touches = 0
    last_x = 0
    last_y = 0

    try:
        for event in dev.read_loop():
            if event.type == ecodes.EV_ABS:
                if event.code == ecodes.ABS_MT_SLOT:
                    current_slot = event.value
                    ui.write(event.type, event.code, event.value)
                elif event.code == ecodes.ABS_MT_TRACKING_ID:
                    # TRACKING_ID == -1 indicates slot release.
                    if event.value == -1:
                        active_touches = max(0, active_touches - 1)
                    else:
                        active_touches += 1
                    ui.write(event.type, event.code, event.value)
                elif event.code == ecodes.ABS_MT_POSITION_X:
                    x = scale(event.value, abs_x.min, abs_x.max, screen_w)
                    last_x = x
                    ui.write(event.type, event.code, x)
                    ui.write(ecodes.EV_ABS, ecodes.ABS_X, x)
                elif event.code == ecodes.ABS_MT_POSITION_Y:
                    y = scale(event.value, abs_y.min, abs_y.max, screen_h)
                    last_y = y
                    ui.write(event.type, event.code, y)
                    ui.write(ecodes.EV_ABS, ecodes.ABS_Y, y)
                else:
                    # Pass through any other ABS_MT_* codes untouched.
                    ui.write(event.type, event.code, event.value)

            elif event.type == ecodes.EV_SYN and event.code == ecodes.SYN_REPORT:
                # Update BTN_TOUCH based on whether any slots are active.
                active_flag = 1 if active_touches > 0 else 0
                ui.write(ecodes.EV_KEY, ecodes.BTN_TOUCH, active_flag)
                ui.write(ecodes.EV_KEY, ecodes.BTN_TOOL_FINGER, active_flag)
                ui.syn()
            else:
                # Ignore non-ABS and non-SYN events for this minimal bridge.
                pass
    except KeyboardInterrupt:
        pass
    finally:
        ui.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
