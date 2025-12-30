#!/usr/bin/env python3
import argparse
import json
import math
import os
import platform
import stat
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
	print(
		"touchpad_joy_bridge: starting (debug banner)\n"
		"  platform: {}\n"
		"  note: Linux evdev/uinput backend only; Windows support is pending.\n".format(
			platform.system()
		),
		file=sys.stderr,
	)

	parser = argparse.ArgumentParser(description="Touchpad MT -> virtual joystick (steering)")
	parser.add_argument("device", nargs="?", help="/dev/input/eventX for the touchpad")
	parser.add_argument("--auto", action="store_true", help="auto-detect a touchpad device")
	parser.add_argument("--name", help="name substring to match for auto-detect")
	parser.add_argument("--config", help="path to JSON config file")
	parser.add_argument("--state", help="path to write JSON state for HUD")
	args = parser.parse_args()

	def _check_permissions(dev_path):
		problems = []
		if os.path.exists("/dev/uinput"):
			if not os.access("/dev/uinput", os.W_OK):
				problems.append("no write access to /dev/uinput")
		else:
			problems.append("/dev/uinput missing (load with: sudo modprobe uinput)")

		if dev_path and os.path.exists(dev_path):
			if not os.access(dev_path, os.R_OK):
				problems.append(f"no read access to {dev_path}")
		return problems

	def _print_permission_help(dev_path, problems):
		print("Permission issue detected:", file=sys.stderr)
		for p in problems:
			print(f"  - {p}", file=sys.stderr)
		print("Fix options (pick one):", file=sys.stderr)
		print("  1) Add user to input group and relogin:", file=sys.stderr)
		print("     sudo usermod -aG input $USER", file=sys.stderr)
		print("  2) Temporarily allow access (current session):", file=sys.stderr)
		if dev_path:
			print(f"     sudo chmod a+r {dev_path}", file=sys.stderr)
		print("     sudo chmod a+rw /dev/uinput", file=sys.stderr)
		print("  3) Permanent udev rule (recommended):", file=sys.stderr)
		print("     sudo tee /etc/udev/rules.d/99-touchpad-joy.rules <<'EOF'", file=sys.stderr)
		print("     KERNEL==\"uinput\", MODE=\"0660\", GROUP=\"input\"", file=sys.stderr)
		if dev_path:
			print("     SUBSYSTEM==\"input\", KERNEL==\"event*\", MODE=\"0660\", GROUP=\"input\"", file=sys.stderr)
		print("     EOF", file=sys.stderr)
		print("     sudo udevadm control --reload-rules && sudo udevadm trigger", file=sys.stderr)

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

	problems = _check_permissions(dev.path if dev else None)
	if problems:
		_print_permission_help(dev.path if dev else None, problems)
		return 2

	# Grab the device so the desktop cursor does not move.
	try:
		dev.grab()
	except OSError as exc:
		print(f"Warning: could not grab device ({exc}). Cursor may still move.")

	abs_x = dev.absinfo(ecodes.ABS_MT_POSITION_X)
	abs_y = dev.absinfo(ecodes.ABS_MT_POSITION_Y)

	# Virtual joystick with X/Y axes, four gear buttons, and touch flags.
	capabilities = {
		ecodes.EV_ABS: [
			(ecodes.ABS_X, AbsInfo(0, -32768, 32767, 0, 0, 0)),
			(ecodes.ABS_Y, AbsInfo(0, -32768, 32767, 0, 0, 0)),
			(ecodes.ABS_RX, AbsInfo(0, -32768, 32767, 0, 0, 0)),
			(ecodes.ABS_RY, AbsInfo(0, -32768, 32767, 0, 0, 0)),
			(ecodes.ABS_Z, AbsInfo(0, -32768, 32767, 0, 0, 0)),
			(ecodes.ABS_RZ, AbsInfo(0, -32768, 32767, 0, 0, 0)),
			(ecodes.ABS_HAT0X, AbsInfo(0, -32768, 32767, 0, 0, 0)),
			(ecodes.ABS_HAT0Y, AbsInfo(0, -32768, 32767, 0, 0, 0)),
		],
		ecodes.EV_KEY: [
			ecodes.BTN_JOYSTICK,
			ecodes.BTN_SOUTH,
			ecodes.BTN_EAST,
			ecodes.BTN_WEST,
			ecodes.BTN_NORTH,
			ecodes.BTN_SELECT,
			ecodes.BTN_START,
			ecodes.BTN_THUMBL,
			ecodes.BTN_TR,
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
			"neutral_reset_hold": 0.15,
			"throttle_neutral_band": 0.2,
			"throttle_sensitivity": 1.0,
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
	state_path = args.state
	last_state_write = 0.0

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
	brake_pressed = False
	lock_active = False
	locked_gear = 0
	last_throttle = 0.0
	neutral_since = 0.0
	throttle_mode_until = 0.0
	throttle_last_avg = None

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
						slots[current_slot] = {"id": event.value, "x": None, "y": None, "side": None}
				elif event.code == ecodes.ABS_MT_POSITION_X:
					slot = slots.setdefault(current_slot, {"id": None, "x": None, "y": None})
					slot["x"] = event.value
					if slot.get("side") is None:
						slot["side"] = "left" if event.value < center_x else "right"
				elif event.code == ecodes.ABS_MT_POSITION_Y:
					slot = slots.setdefault(current_slot, {"id": None, "x": None, "y": None})
					slot["y"] = event.value
			elif event.type == ecodes.EV_KEY:
				if event.code in (ecodes.BTN_LEFT, ecodes.BTN_RIGHT, ecodes.BTN_MIDDLE):
					brake_pressed = event.value == 1

			elif event.type == ecodes.EV_SYN and event.code == ecodes.SYN_REPORT:
				# Use the leftmost active slot on the left half for steering.
				steer = 0
				active_flag = 0
				steer_slot = None
				left_touch_active = False
				left_finger = None
				for s in sorted(slots.keys()):
					info = slots[s]
					if info.get("x") is None or info.get("y") is None:
						continue
					if info.get("side") == "left":
						left_touch_active = True
						if left_finger == None:
							left_finger = info
						if info["x"] < center_x and steer_slot == None:
							steer_slot = info
				if steer_slot:
					dx = steer_slot["x"] - steer_center_x
					dy = steer_slot["y"] - center_y
					# Normalize Y so the steering motion feels circular on rectangular pads.
					dy *= (center_x - abs_x.min) / max(1.0, (abs_y.max - abs_y.min))
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

				# Right-side fingers control the shifter and throttle.
				gear = last_gear
				gear_candidate = last_gear
				throttle = last_throttle
				right_fingers = []
				for s in sorted(slots.keys()):
					info = slots[s]
					if info.get("x") is None or info.get("y") is None:
						continue
					if info.get("side") == "right" and info["x"] >= right_min_x:
						right_fingers.append(info)

				now = time.monotonic()
				if len(right_fingers) >= 2:
					if not lock_active:
						locked_gear = last_gear
						lock_active = True
					gear = locked_gear
					gear_candidate = locked_gear
					avg_v = sum(
						(f["y"] - abs_y.min) / max(1.0, (abs_y.max - abs_y.min))
						for f in right_fingers
					) / len(right_fingers)
					if throttle_last_avg is None:
						throttle_last_avg = avg_v
					var_delta = (throttle_last_avg - avg_v) * config["throttle_sensitivity"]
					throttle = max(-1.0, min(1.0, throttle + var_delta * 2.0))
					throttle_last_avg = avg_v
					last_throttle = throttle
					throttle_mode_until = now + 0.2
				else:
					lock_active = False
					throttle_last_avg = None
					if now < throttle_mode_until:
						gear = last_gear
					elif len(right_fingers) == 1:
						f = right_fingers[0]
						u = (f["x"] - right_min_x) / max(1.0, (right_max_x - right_min_x))
						v = (f["y"] - abs_y.min) / max(1.0, (abs_y.max - abs_y.min))
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
							gear_candidate = 0
						elif row != -1 and col != -1:
							if col == 1:
								row = 1 - row
							gear_candidate = col * 2 + row + 1

				if gear_candidate != last_gear:
					if pending_gear != gear_candidate:
						pending_gear = gear_candidate
						pending_since = now
					hold_time = config["gear_hold_time"]
					if gear_candidate == 0:
						hold_time = config["neutral_reset_hold"]
					if now - pending_since >= hold_time:
						gear = gear_candidate
						last_gear = gear_candidate
				else:
					pending_gear = gear_candidate
					pending_since = now

				right_axes = [0, 0, 0, 0]
				for i, f in enumerate(right_fingers[:2]):
					u = (f["x"] - right_min_x) / max(1.0, (right_max_x - right_min_x))
					v = (f["y"] - abs_y.min) / max(1.0, (abs_y.max - abs_y.min))
					u = max(0.0, min(1.0, u))
					v = max(0.0, min(1.0, v))
					right_axes[i * 2] = int((u * 2.0 - 1.0) * 32767)
					right_axes[i * 2 + 1] = int((v * 2.0 - 1.0) * 32767)

				left_axes = [0, 0]
				if left_finger:
					u = (left_finger["x"] - abs_x.min) / max(1.0, (center_x - abs_x.min))
					v = (left_finger["y"] - abs_y.min) / max(1.0, (abs_y.max - abs_y.min))
					u = max(0.0, min(1.0, u))
					v = max(0.0, min(1.0, v))
					left_axes[0] = int((u * 2.0 - 1.0) * 32767)
					left_axes[1] = int((v * 2.0 - 1.0) * 32767)
				ui.write(ecodes.EV_ABS, ecodes.ABS_X, steer)
				band = max(0.0, min(0.6, config["throttle_neutral_band"]))
				var_out = 0.0
				if abs(throttle) >= band:
					var_out = (abs(throttle) - band) / (1.0 - band)
					if throttle < 0.0:
						var_out = -var_out
				ui.write(ecodes.EV_ABS, ecodes.ABS_Y, int(max(-1.0, min(1.0, var_out)) * 32767))
				ui.write(ecodes.EV_ABS, ecodes.ABS_RX, right_axes[0])
				ui.write(ecodes.EV_ABS, ecodes.ABS_RY, right_axes[1])
				ui.write(ecodes.EV_ABS, ecodes.ABS_Z, right_axes[2])
				ui.write(ecodes.EV_ABS, ecodes.ABS_RZ, right_axes[3])
				ui.write(ecodes.EV_ABS, ecodes.ABS_HAT0X, left_axes[0])
				ui.write(ecodes.EV_ABS, ecodes.ABS_HAT0Y, left_axes[1])
				ui.write(ecodes.EV_KEY, ecodes.BTN_JOYSTICK, active_flag)
				ui.write(ecodes.EV_KEY, ecodes.BTN_SOUTH, 1 if gear == 1 else 0)
				ui.write(ecodes.EV_KEY, ecodes.BTN_EAST, 1 if gear == 2 else 0)
				ui.write(ecodes.EV_KEY, ecodes.BTN_WEST, 1 if gear == 3 else 0)
				ui.write(ecodes.EV_KEY, ecodes.BTN_NORTH, 1 if gear == 4 else 0)
				ui.write(ecodes.EV_KEY, ecodes.BTN_SELECT, 1 if brake_pressed else 0)
				ui.write(ecodes.EV_KEY, ecodes.BTN_START, 1 if len(right_fingers) > 0 else 0)
				ui.write(ecodes.EV_KEY, ecodes.BTN_THUMBL, 1 if left_touch_active else 0)
				ui.write(ecodes.EV_KEY, ecodes.BTN_TR, 1 if len(right_fingers) > 1 else 0)
				ui.syn()

				if state_path and now - last_state_write > 0.02:
					left_active = left_finger is not None
					left_x = 0.0
					left_y = 0.0
					if left_finger:
						left_x = (left_finger["x"] - abs_x.min) / max(1.0, (center_x - abs_x.min))
						left_y = (left_finger["y"] - abs_y.min) / max(1.0, (abs_y.max - abs_y.min))
						left_x = max(0.0, min(1.0, left_x))
						left_y = max(0.0, min(1.0, left_y))
					try:
						with open(state_path, "w", encoding="ascii") as f:
							f.write(
								json.dumps(
									{"left": {"active": left_active, "x": left_x, "y": left_y}}
								)
							)
					except OSError:
						pass
					last_state_write = now

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
