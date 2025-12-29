#!/usr/bin/env python3
import argparse
import json
import math
import sys
import time
from evdev import AbsInfo, InputDevice, UInput, ecodes, list_devices

# Touchpad MT -> virtual joystick bridge (single-finger steering on X axis).


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

    for dev in candidates:
        n = dev.name.lower()
        if "touchpad" in n or "trackpad" in n:
            return dev

    return candidates[0]


def scale_to_axis(value, in_min, in_max, out_min=-32768, out_max=32767):
    if in_max == in_min:
        return 0
    v = max(in_min, min(in_max, value))
    return int((v - in_min) * (out_max - out_min) / (in_max - in_min) + out_min)


def main():
    parser = argparse.ArgumentParser(description="Touchpad MT -> virtual joystick (steering)")
    parser.add_argument("device", nargs="?", help="/dev/input/eventX for the touchpad")
    parser.add_argument("--auto", action="store_true", help="auto-detect a touchpad device")
    parser.add_argument("--name", help="name substring to match for auto-detect")
    parser.add_argument("--config", help="path to JSON config file")
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

    # Grab the device so the desktop cursor does not move.
    try:
        dev.grab()
    except OSError as exc:
        print(f"Warning: could not grab device ({exc}). Cursor may still move.")

    abs_x = dev.absinfo(ecodes.ABS_MT_POSITION_X)
    abs_y = dev.absinfo(ecodes.ABS_MT_POSITION_Y)

    # Virtual joystick with X/Y axes, four gear buttons, and reverse.
    capabilities = {
        ecodes.EV_ABS: [
            (ecodes.ABS_X, AbsInfo(0, -32768, 32767, 0, 0, 0)),
            (ecodes.ABS_Y, AbsInfo(0, -32768, 32767, 0, 0, 0)),
        ],
        ecodes.EV_KEY: [
            ecodes.BTN_JOYSTICK,
            ecodes.BTN_SOUTH,
            ecodes.BTN_EAST,
            ecodes.BTN_WEST,
            ecodes.BTN_NORTH,
            ecodes.BTN_SELECT,
        ],
    }

    ui = UInput(
        capabilities,
        name="touchpad-virtual-joystick",
        bustype=ecodes.BUS_USB,
        vendor=0x1234,
        product=0x5678,
        version=1,
    )

    def load_config(path):
        defaults = {
            "steer_delta_scale": 0.1,
            "steer_deadzone": 10.0,
            "shift_margin": 0.12,
            "shift_gap": 0.18,
            "neutral_min": 0.45,
            "neutral_max": 0.55,
            "gear_hold_time": 0.12,
        }
        if not path:
            return defaults
        try:
            with open(path, "r", encoding="ascii") as f:
                data = json.load(f)
            defaults.update({k: data.get(k, v) for k, v in defaults.items()})
        except OSError:
            pass
        except json.JSONDecodeError:
            pass
        return defaults

    config_path = args.config
    config = load_config(config_path)
    last_config_check = 0.0

    current_slot = 0
    slots = {}
    center_x = (abs_x.min + abs_x.max) / 2.0
    center_y = (abs_y.min + abs_y.max) / 2.0
    steer_center_x = (abs_x.min + center_x) / 2.0
    right_min_x = center_x
    right_max_x = abs_x.max
    last_angle = None
    last_gear = 0
    neutral_latched = True
    pending_gear = 0
    pending_since = 0.0
    gear_hold_time = 0.12
    reverse_pressed = False

    last_print = 0.0

    try:
        for event in dev.read_loop():
            if event.type == ecodes.EV_ABS:
                if event.code == ecodes.ABS_MT_SLOT:
                    current_slot = event.value
                elif event.code == ecodes.ABS_MT_TRACKING_ID:
                    if event.value == -1:
                        slots.pop(current_slot, None)
                    else:
                        slots[current_slot] = {"id": event.value, "x": None, "y": None}
                elif event.code == ecodes.ABS_MT_POSITION_X:
                    slot = slots.setdefault(current_slot, {"id": None, "x": None, "y": None})
                    slot["x"] = event.value
                elif event.code == ecodes.ABS_MT_POSITION_Y:
                    slot = slots.setdefault(current_slot, {"id": None, "x": None, "y": None})
                    slot["y"] = event.value
            elif event.type == ecodes.EV_KEY:
                if event.code in (ecodes.BTN_LEFT, ecodes.BTN_RIGHT, ecodes.BTN_MIDDLE):
                    reverse_pressed = event.value == 1

            elif event.type == ecodes.EV_SYN and event.code == ecodes.SYN_REPORT:
                # Use the leftmost active slot on the left half for steering.
                steer = 0
                active_flag = 0
                steer_slot = None
                for s in sorted(slots.keys()):
                    info = slots[s]
                    if info.get("x") is None or info.get("y") is None:
                        continue
                    if info["x"] < center_x:
                        steer_slot = info
                        break
                if steer_slot:
                    dx = steer_slot["x"] - steer_center_x
                    dy = steer_slot["y"] - center_y
                    dist = math.hypot(dx, dy)
                    if dist > config["steer_deadzone"]:
                        angle = math.atan2(dy, dx)
                        if last_angle is not None:
                            delta = math.atan2(math.sin(angle - last_angle), math.cos(angle - last_angle))
                            if abs(delta) < 0.01:
                                delta = 0.0
                            steer = int(max(-1.0, min(1.0, delta / config["steer_delta_scale"])) * 32767)
                        last_angle = angle
                        active_flag = 1
                    else:
                        last_angle = None
                else:
                    last_angle = None

                # The leftmost active slot on the right half controls the 2x2 H-pattern shifter.
                gear = 0
                shift_slot = None
                for s in sorted(slots.keys()):
                    info = slots[s]
                    if info.get("x") is None or info.get("y") is None:
                        continue
                    if info["x"] >= right_min_x:
                        shift_slot = info
                        break
                if shift_slot:
                    u = (shift_slot["x"] - right_min_x) / max(1.0, (right_max_x - right_min_x))
                    v = (shift_slot["y"] - abs_y.min) / max(1.0, (abs_y.max - abs_y.min))
                    now = time.monotonic()
                    neutral_min = config["neutral_min"]
                    neutral_max = config["neutral_max"]
                    in_neutral = (
                        neutral_min <= u <= neutral_max
                        or neutral_min <= v <= neutral_max
                    )

                    col = -1
                    if u < neutral_min:
                        col = 0
                    elif u > neutral_max:
                        col = 1

                    row = -1
                    if v < neutral_min:
                        row = 0
                    elif v > neutral_max:
                        row = 1

                    if in_neutral:
                        gear = 0
                        neutral_latched = True
                        last_gear = 0
                        pending_gear = 0
                    elif row != -1 and col != -1:
                        if col == 1:
                            row = 1 - row
                        gear_candidate = col * 2 + row + 1
                        if neutral_latched:
                            if gear_candidate != pending_gear:
                                pending_gear = gear_candidate
                                pending_since = now
                            if now - pending_since >= config["gear_hold_time"]:
                                gear = gear_candidate
                                neutral_latched = False
                                pending_gear = 0
                            else:
                                gear = last_gear
                        elif gear_candidate == last_gear:
                            gear = last_gear
                            pending_gear = 0
                        else:
                            gear = last_gear
                            pending_gear = 0
                    else:
                        gear = 0
                        neutral_latched = True
                        last_gear = 0
                        pending_gear = 0
                else:
                    gear = 0
                    neutral_latched = True
                    last_gear = 0
                    pending_gear = 0

                if gear != 0:
                    last_gear = gear
                ui.write(ecodes.EV_ABS, ecodes.ABS_X, steer)
                ui.write(ecodes.EV_ABS, ecodes.ABS_Y, 0)
                ui.write(ecodes.EV_KEY, ecodes.BTN_JOYSTICK, active_flag)
                ui.write(ecodes.EV_KEY, ecodes.BTN_SOUTH, 1 if gear == 1 else 0)
                ui.write(ecodes.EV_KEY, ecodes.BTN_EAST, 1 if gear == 2 else 0)
                ui.write(ecodes.EV_KEY, ecodes.BTN_WEST, 1 if gear == 3 else 0)
                ui.write(ecodes.EV_KEY, ecodes.BTN_NORTH, 1 if gear == 4 else 0)
                ui.write(ecodes.EV_KEY, ecodes.BTN_SELECT, 1 if reverse_pressed else 0)
                ui.syn()

                # Reload config periodically for live tuning.
                if config_path:
                    now = time.monotonic()
                    if now - last_config_check > 0.25:
                        config = load_config(config_path)
                        last_config_check = now

                # Minimal live readout in the console (10 Hz).
                now = time.time()
                if now - last_print > 0.1:
                    parts = []
                    for s in sorted(slots.keys()):
                        info = slots[s]
                        parts.append(f"slot{s}: x={info.get('x')} y={info.get('y')}")
                    line = " | ".join(parts) if parts else "(no touches)"
                    print("\r" + line + " " * 10, end="", flush=True)
                    last_print = now

    except KeyboardInterrupt:
        pass
    finally:
        try:
            dev.ungrab()
        except Exception:
            pass
        ui.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
