extends "res://VehicleSettings.gd"

const GEAR_MAX_SPEED_KMH := {
	1: 30.0,
	2: 55.0,
	3: 90.0,
	4: 140.0,
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

func _ready():
	# Start the touchpad->joystick bridge so Godot can read joystick input
	var script_path = ProjectSettings.globalize_path("res://touchpad_joy_bridge.py")
	config_path = ProjectSettings.globalize_path("user://touchpad_joy_config.json")
	state_path = ProjectSettings.globalize_path("user://touchpad_joy_state.json")
	_write_config()
	bridge_pid = _start_bridge(script_path)
	tree_exiting.connect(_on_tree_exiting)
	_cache_wheel_nodes()
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

func _physics_process(delta):
	_check_respawn()
	_read_bridge_state()
	_update_input()
	_apply_vehicle(delta)
	_update_steering_wheel()
	_write_config()

func _update_input():
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

func _apply_vehicle(_delta):
	if not front_left or not front_right or not rear_left or not rear_right:
		return
	if auto_center_steer and abs(steer) < 0.01 and not left_touch_active:
		steer_angle = lerp(steer_angle, 0.0, clamp(steer_return_rate * _delta, 0.0, 1.0))
	else:
		steer_angle += steer * steer_rate * _delta
	steer_angle = clamp(steer_angle, -max_steer, max_steer)
	front_left.steering = -steer_angle
	front_right.steering = -steer_angle

	var engine_force = 0.0
	var brake = 0.0
	if brake_pressed:
		brake = max_brake
	if gear > 0:
		var ratio = _gear_ratio(gear)
		engine_force = max_engine_force * ratio * throttle
		var speed_kmh = linear_velocity.length() * 3.6
		var max_speed = GEAR_MAX_SPEED_KMH.get(gear, 80.0)
		var limit = clamp(1.0 - (speed_kmh / max_speed), 0.0, 1.0)
		engine_force *= limit
	elif gear < 0:
		engine_force = -reverse_force * abs(throttle)
	if brake > 0.0:
		engine_force = 0.0

	rear_left.engine_force = engine_force
	rear_right.engine_force = engine_force
	front_left.brake = brake
	front_right.brake = brake
	rear_left.brake = brake
	rear_right.brake = brake

func _gear_ratio(value):
	match value:
		1:
			return 2.4
		2:
			return 1.6
		3:
			return 1.05
		4:
			return 0.45
		_:
			return 0.5

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

func _read_touchpad_input(pad):
	steer = _apply_deadzone(Input.get_joy_axis(pad, JOY_AXIS_LEFT_X), 0.05)
	right_touch_active = Input.is_joy_button_pressed(pad, JOY_BUTTON_START)
	left_touch_active = Input.is_joy_button_pressed(pad, JOY_BUTTON_LEFT_STICK)
	right_two_fingers = Input.is_joy_button_pressed(pad, JOY_BUTTON_RIGHT_SHOULDER)
	brake_pressed = Input.is_joy_button_pressed(pad, JOY_BUTTON_BACK)
	if right_touch_active:
		throttle = clamp(Input.get_joy_axis(pad, JOY_AXIS_LEFT_Y), -1.0, 1.0)
	var new_gear = _read_gear(pad)
	if new_gear != 0:
		gear = new_gear
	right_f1 = Vector2(
		Input.get_joy_axis(pad, JOY_AXIS_RIGHT_X),
		Input.get_joy_axis(pad, JOY_AXIS_RIGHT_Y)
	)
	right_f2 = Vector2(
		_axis_to_signed(Input.get_joy_axis(pad, JOY_AXIS_TRIGGER_LEFT)),
		_axis_to_signed(Input.get_joy_axis(pad, JOY_AXIS_TRIGGER_RIGHT))
	)

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
		var name = Input.get_joy_name(pad).to_lower()
		if name.find("touchpad-virtual-joystick") != -1:
			return pad
	return -1

func _find_controller_pad(pads):
	for pad in pads:
		var name = Input.get_joy_name(pad).to_lower()
		if name.find("touchpad-virtual-joystick") == -1:
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
	right_f1 = Vector2.ZERO
	right_f2 = Vector2.ZERO
	right_two_fingers = false
	left_f1 = Vector2.ZERO
	left_finger_active = false
	left_touch_active = false
	right_touch_active = false
	brake_pressed = false

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
