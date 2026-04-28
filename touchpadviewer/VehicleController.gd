extends "res://VehicleSettings.gd"

enum ControlMode { NONE = 0, SHIFT = 1, NO_SHIFT = 2 }
var control_mode: int = ControlMode.NONE
var _throttle_latch := 0.0
var _gear_latch := 1

const GEAR_MAX_SPEED_KMH := {
	1: 18.0,
	2: 38.0,
	3: 65.0,
	4: 100.0,
}

# Bridge process id
var bridge_pid := -1
var config_path := ""
var state_path := ""
var _last_config := {}

@export var bridge_debug_terminal := false

@export var steer_delta_scale := 0.1
@export var steer_deadzone := 10.0
@export var shift_margin := 0.12
@export var shift_gap := 0.18
@export var neutral_min := 0.45
@export var neutral_max := 0.55
@export var gear_hold_time := 0.12
@export var neutral_reset_hold := 0.15
@export var throttle_neutral_band := 0.2
@export var throttle_sensitivity := 0.6
@export var controller_deadzone := 0.2
@export var auto_center_steer := false

var front_left
var front_right
var rear_left
var rear_right

var gear := 1
var steer := 0.0
var steer_angle := 0.0
var throttle := 0.0
var right_touch_active := false
var left_touch_active := false
var right_f1 := Vector2.ZERO
var right_f2 := Vector2.ZERO
var right_two_fingers := false
var left_f1 := Vector2.ZERO
var left_finger_active := false
var brake_pressed := false

@export var respawn_height := -5.0
@export var respawn_position := Vector3(0, 1.2, 0)
@export var respawn_rotation := Vector3.ZERO
@export var steering_wheel_path := NodePath("ChassisModel/carwithinteriour/SteeringWheel")

var steering_wheel
var steering_wheel_basis
var using_bridge := false
var fallback_notice := ""
var _fallback_active_until := 0
var _bridge_script_path := ""
var _fallback_steer := 0.0

@export var allow_fallback_on_linux := true
@export var fallback_mouse_sensitivity := 0.008

func _ready():
	var os_name = OS.get_name()
	using_bridge = os_name == "Linux"
	if using_bridge:
		_bridge_script_path = _ensure_bridge_script("touchpad_joy_bridge.py")
		config_path = ProjectSettings.globalize_path("user://touchpad_joy_config.json")
		state_path = ProjectSettings.globalize_path("user://touchpad_joy_state.json")
		_write_config()
		# Bridge launch deferred until mode is selected
		tree_exiting.connect(_on_tree_exiting)
	else:
		fallback_notice = "Mouse fallback: move to steer, scroll = throttle, any click = brake."
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	set_process_input(true)

	# Mountain truck physics overrides (applied regardless of scene inspector values)
	max_engine_force = 17000.0
	reverse_force = 6000.0
	max_brake = 35.0
	steer_rate = 1.1
	auto_center_steer = false

	_cache_wheel_nodes()

	# Wheel tuning for off-road traction
	for wheel in [front_left, front_right, rear_left, rear_right]:
		if wheel:
			wheel.wheel_friction_slip = 2.3
	# Enable 4WD on front wheels (scene has use_as_traction=false by default)
	if front_left:
		front_left.use_as_traction = true
	if front_right:
		front_right.use_as_traction = true

	_cache_steering_wheel()
	respawn_position = global_transform.origin
	respawn_rotation = rotation

func _exit_tree():
	_stop_bridge()

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_stop_bridge()

func _on_tree_exiting():
	_stop_bridge()

func _stop_bridge():
	if bridge_pid > 0:
		OS.kill(bridge_pid)
		bridge_pid = -1

func launch_bridge() -> void:
	if using_bridge and bridge_pid <= 0 and not _bridge_script_path.is_empty():
		bridge_pid = _start_bridge(_bridge_script_path)

func _start_bridge(script_path):
	var args = [script_path, "--auto", "--config", config_path, "--state", state_path]
	if not bridge_debug_terminal:
		return OS.create_process("python3", args)

	var candidates = [
		["x-terminal-emulator", ["-e", "python3"] + args],
		["gnome-terminal", ["--", "python3"] + args],
		["konsole", ["-e", "python3"] + args],
		["xterm", ["-e", "python3"] + args],
	]
	for entry in candidates:
		var pid = OS.create_process(entry[0], entry[1])
		if pid > 0:
			return pid
	return OS.create_process("python3", args)

func _ensure_bridge_script(filename):
	var src_path = "res://%s" % filename
	var dst_path = "user://%s" % filename
	if not FileAccess.file_exists(dst_path):
		var bytes = FileAccess.get_file_as_bytes(src_path)
		if bytes.size() > 0:
			var file = FileAccess.open(dst_path, FileAccess.WRITE)
			if file:
				file.store_buffer(bytes)
				file.close()
	return ProjectSettings.globalize_path(dst_path)

@export var air_roll_torque    := 12000.0
@export var air_upright_torque := 20000.0

func _physics_process(delta):
	_check_respawn()
	if using_bridge:
		_read_bridge_state()
	_update_input()
	_apply_vehicle(delta)
	_apply_air_controls()
	_update_steering_wheel()
	if using_bridge:
		_write_config()

func _check_airborne() -> bool:
	if not front_left or not front_right or not rear_left or not rear_right:
		return false
	return (not front_left.is_in_contact() and not front_right.is_in_contact() and
			not rear_left.is_in_contact() and not rear_right.is_in_contact())

func _apply_air_controls() -> void:
	if not _check_airborne():
		return
	var up := global_transform.basis.y
	var inverted := up.dot(Vector3.UP) < 0.0
	var torque := Vector3.ZERO
	if inverted:
		# Strong auto-upright torque + steering assists the flip
		var tilt_axis := up.cross(Vector3.UP)
		if tilt_axis.length_squared() > 0.001:
			torque += tilt_axis.normalized() * air_upright_torque
		torque += global_transform.basis.z * steer * air_roll_torque * 2.0
	else:
		# Normal air: steering rolls the car (useful for jumps / repositioning)
		torque += global_transform.basis.z * steer * air_roll_torque
	apply_torque(torque)

func _update_input():
	if not using_bridge:
		_read_fallback_input()
		return
	if allow_fallback_on_linux and _fallback_is_active():
		_read_fallback_input()
		return
	var pads = Input.get_connected_joypads()
	if pads.size() == 0:
		_reset_input_state()
		return
	var virtual_pad = _find_virtual_pad(pads)
	var controller_pad = _find_controller_pad(pads)

	if controller_pad != -1:
		_read_controller_input(controller_pad)
	else:
		_read_touchpad_input(virtual_pad if virtual_pad != -1 else pads[0])

func _apply_vehicle(_delta: float) -> void:
	if not front_left or not front_right or not rear_left or not rear_right:
		return

	# Freeze vehicle until mode is selected
	if control_mode == ControlMode.NONE:
		for w in [front_left, front_right, rear_left, rear_right]:
			w.brake = max_brake
			w.engine_force = 0.0
		return

	# Steering accumulation — never auto-centers (auto_center_steer stays false)
	if auto_center_steer and abs(steer) < 0.01 and not left_touch_active:
		steer_angle = lerp(steer_angle, 0.0, clamp(steer_return_rate * _delta, 0.0, 1.0))
	else:
		steer_angle += steer * steer_rate * _delta
	steer_angle = clamp(steer_angle, -max_steer, max_steer)
	front_left.steering = -steer_angle
	front_right.steering = -steer_angle

	var eng_force: float = 0.0
	var brk_force: float = 0.0

	if brake_pressed:
		brk_force = max_brake
	elif abs(throttle) < 0.05:
		brk_force = max_brake * 0.12  # engine braking when coasting

	if gear > 0 and not brake_pressed:
		var ratio: float = _gear_ratio(gear)
		var spd: float = linear_velocity.length() * 3.6
		var max_spd: float = GEAR_MAX_SPEED_KMH.get(gear, 80.0)
		# Quadratic dropoff — more torque mid-range vs old linear limiter
		var limit: float = clamp(1.0 - pow(spd / max_spd, 2.0), 0.0, 1.0)
		eng_force = max_engine_force * ratio * throttle * limit
	elif gear < 0 and not brake_pressed:
		eng_force = -reverse_force * abs(throttle)

	# 4WD — all wheels receive engine force
	for w in [front_left, front_right, rear_left, rear_right]:
		w.engine_force = eng_force
		w.brake = brk_force

func _gear_ratio(v: int) -> float:
	match v:
		1: return 4.0
		2: return 2.5
		3: return 1.5
		4: return 0.65
		_: return 1.0

func _auto_gear() -> int:
	var s := linear_velocity.length() * 3.6
	if s < 15.0:
		return 1
	elif s < 35.0:
		return 2
	elif s < 60.0:
		return 3
	else:
		return 4

func _read_bridge_state():
	if state_path.is_empty():
		return
	if not FileAccess.file_exists(state_path):
		left_finger_active = false
		return
	var file = FileAccess.open(state_path, FileAccess.READ)
	if not file:
		left_finger_active = false
		return
	var content = file.get_as_text()
	file.close()
	var data = JSON.parse_string(content)
	if typeof(data) != TYPE_DICTIONARY:
		left_finger_active = false
		return
	var left = data.get("left", {})
	if typeof(left) != TYPE_DICTIONARY:
		left_finger_active = false
		return
	left_finger_active = bool(left.get("active", false))
	var lx = float(left.get("x", 0.5))
	var ly = float(left.get("y", 0.5))
	left_f1 = Vector2(lx * 2.0 - 1.0, ly * 2.0 - 1.0)

func _cache_wheel_nodes():
	front_left = get_node_or_null("FrontLeft")
	front_right = get_node_or_null("FrontRight")
	rear_left = get_node_or_null("RearLeft")
	rear_right = get_node_or_null("RearRight")
	if not front_left or not front_right or not rear_left or not rear_right:
		push_warning("Vehicle wheel nodes missing under Vehicle instance.")

func _cache_steering_wheel():
	if steering_wheel_path == NodePath():
		return
	steering_wheel = get_node_or_null(steering_wheel_path)
	if not steering_wheel:
		steering_wheel = find_child("SteeringWheel", true, false)
	if steering_wheel:
		steering_wheel_basis = steering_wheel.transform.basis
	if not steering_wheel:
		push_warning("Steering wheel node missing at: %s" % [steering_wheel_path])

func _update_steering_wheel():
	if not steering_wheel:
		return
	var t = steering_wheel.transform
	t.basis = steering_wheel_basis * Basis(Vector3.UP, -steer_angle * 2.0)
	steering_wheel.transform = t

func _read_controller_input(pad):
	right_touch_active = true
	left_touch_active = false
	right_two_fingers = false
	left_finger_active = false
	left_f1 = Vector2.ZERO
	right_f1 = Vector2.ZERO
	right_f2 = Vector2.ZERO
	brake_pressed = Input.is_joy_button_pressed(pad, JOY_BUTTON_BACK)

	steer = _apply_deadzone(Input.get_joy_axis(pad, JOY_AXIS_LEFT_X), controller_deadzone)
	throttle = _apply_deadzone(-Input.get_joy_axis(pad, JOY_AXIS_LEFT_Y), controller_deadzone)

	var rx = Input.get_joy_axis(pad, JOY_AXIS_RIGHT_X)
	var ry = Input.get_joy_axis(pad, JOY_AXIS_RIGHT_Y)
	if not (abs(rx) < controller_deadzone and abs(ry) < controller_deadzone):
		var col = 0 if rx < 0.0 else 1
		var row = 0 if ry < 0.0 else 1
		if col == 1:
			row = 1 - row
		gear = col * 2 + row + 1

	if Input.is_joy_button_pressed(pad, JOY_BUTTON_BACK):
		gear = -1

func _read_touchpad_input(pad: int) -> void:
	steer = _apply_deadzone(Input.get_joy_axis(pad, JOY_AXIS_LEFT_X), 0.05)
	right_touch_active = Input.is_joy_button_pressed(pad, JOY_BUTTON_START)
	left_touch_active = Input.is_joy_button_pressed(pad, JOY_BUTTON_LEFT_STICK)
	right_two_fingers = Input.is_joy_button_pressed(pad, JOY_BUTTON_RIGHT_SHOULDER)
	brake_pressed = Input.is_joy_button_pressed(pad, JOY_BUTTON_BACK)
	right_f1 = Vector2(
		Input.get_joy_axis(pad, JOY_AXIS_RIGHT_X),
		Input.get_joy_axis(pad, JOY_AXIS_RIGHT_Y)
	)
	right_f2 = Vector2(
		_axis_to_signed(Input.get_joy_axis(pad, JOY_AXIS_TRIGGER_LEFT)),
		_axis_to_signed(Input.get_joy_axis(pad, JOY_AXIS_TRIGGER_RIGHT))
	)

	if control_mode == ControlMode.SHIFT:
		if right_touch_active:
			throttle = clamp(Input.get_joy_axis(pad, JOY_AXIS_LEFT_Y), -1.0, 1.0)
		var g: int = _read_gear(pad)
		if g != 0:
			gear = g

	elif control_mode == ControlMode.NO_SHIFT:
		# right_f1.y: -1=top, +1=bottom
		# Top 65% = forward, middle 5% = neutral, bottom 30% = reverse — latches on lift
		if right_touch_active:
			var yn: float = (right_f1.y + 1.0) * 0.5  # 0=top, 1=bottom
			if yn < 0.65:
				_throttle_latch = 1.0 - (yn / 0.65)
				_gear_latch = _auto_gear()
			elif yn < 0.70:
				_throttle_latch = 0.0
				_gear_latch = _auto_gear()
			else:
				_throttle_latch = (yn - 0.70) / 0.30
				_gear_latch = -1
		throttle = _throttle_latch
		gear = _gear_latch

func _read_fallback_input() -> void:
	left_touch_active = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	right_touch_active = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	left_finger_active = left_touch_active
	right_two_fingers = false
	left_f1 = Vector2.ZERO
	right_f1 = Vector2.ZERO
	_fallback_steer = lerp(_fallback_steer, 0.0, 0.2)
	steer = _fallback_steer
	brake_pressed = (
		Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or
		Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE) or
		Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or
		Input.is_key_pressed(KEY_SPACE)
	)

func _fallback_is_active():
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return true
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		return true
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		return true
	return Time.get_ticks_msec() < _fallback_active_until

func _read_gear(pad_id):
	if Input.is_joy_button_pressed(pad_id, JOY_BUTTON_A):
		return 1
	if Input.is_joy_button_pressed(pad_id, JOY_BUTTON_B):
		return 2
	if Input.is_joy_button_pressed(pad_id, JOY_BUTTON_X):
		return 3
	if Input.is_joy_button_pressed(pad_id, JOY_BUTTON_Y):
		return 4
	return 0

func _find_virtual_pad(pads):
	for pad in pads:
		var pad_name := Input.get_joy_name(pad).to_lower()
		if pad_name.find("touchpad-virtual-joystick") != -1:
			return pad
	return -1

func _find_controller_pad(pads):
	for pad in pads:
		var pad_name := Input.get_joy_name(pad).to_lower()
		if pad_name.find("touchpad-virtual-joystick") == -1:
			return pad
	return -1

func _check_respawn():
	if global_transform.origin.y < respawn_height or Input.is_key_pressed(KEY_R):
		var xform = global_transform
		xform.origin = respawn_position
		global_transform = xform
		rotation = respawn_rotation
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO

func _axis_to_signed(value):
	if value >= 0.0 and value <= 1.0:
		return value * 2.0 - 1.0
	return value

func _apply_deadzone(value, deadzone):
	if abs(value) < deadzone:
		return 0.0
	return value

func _reset_input_state():
	gear = 1
	steer = 0.0
	throttle = 0.0
	_throttle_latch = 0.0
	_gear_latch = 1
	right_f1 = Vector2.ZERO
	right_f2 = Vector2.ZERO
	right_two_fingers = false
	left_f1 = Vector2.ZERO
	left_finger_active = false
	left_touch_active = false
	right_touch_active = false
	brake_pressed = false

func _input(event: InputEvent) -> void:
	if using_bridge:
		if not allow_fallback_on_linux:
			return
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	if event is InputEventMouseButton and event.pressed:
		_fallback_active_until = Time.get_ticks_msec() + 300
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			throttle = clamp(throttle + 0.08, -1.0, 1.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			throttle = clamp(throttle - 0.08, -1.0, 1.0)
	elif event is InputEventMouseMotion:
		_fallback_active_until = Time.get_ticks_msec() + 300
		_fallback_steer = clamp(event.relative.x * fallback_mouse_sensitivity, -1.0, 1.0)

func _write_config():
	var cfg = {
		"steer_delta_scale": steer_delta_scale,
		"steer_deadzone": steer_deadzone,
		"shift_margin": shift_margin,
		"shift_gap": shift_gap,
		"neutral_min": neutral_min,
		"neutral_max": neutral_max,
		"gear_hold_time": gear_hold_time,
		"neutral_reset_hold": neutral_reset_hold,
		"throttle_neutral_band": throttle_neutral_band,
		"throttle_sensitivity": throttle_sensitivity,
	}
	if cfg == _last_config:
		return
	var file = FileAccess.open(config_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(cfg))
		file.close()
	_last_config = cfg
