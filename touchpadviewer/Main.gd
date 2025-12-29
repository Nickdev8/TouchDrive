extends Node3D

# Bridge process id
var bridge_pid := -1
var config_path := ""
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

@onready var vehicle := $Vehicle
@onready var front_left := $Vehicle/FrontLeft
@onready var front_right := $Vehicle/FrontRight
@onready var rear_left := $Vehicle/RearLeft
@onready var rear_right := $Vehicle/RearRight
@onready var camera := $Camera3D
@onready var overlay := $CanvasLayer/Overlay
@onready var vehicle_settings := $Vehicle
@onready var camera_settings := $Camera3D

var gear := 0
var steer := 0.0
var steer_angle := 0.0
var throttle := 0.0
var right_touch_active := false
var left_touch_active := false
var brake_force := 0.0
var camera_yaw := 0.0
var camera_pitch := -0.4
var right_f1 := Vector2.ZERO
var right_f2 := Vector2.ZERO
var right_two_fingers := false

func _ready():
	# Start the touchpad->joystick bridge so Godot can read joystick input
	var script_path = ProjectSettings.globalize_path("res://touchpad_joy_bridge.py")
	config_path = ProjectSettings.globalize_path("user://touchpad_joy_config.json")
	_write_config()
	bridge_pid = _start_bridge(script_path)
	tree_exiting.connect(_on_tree_exiting)

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
	var args = [script_path, "--auto", "--config", config_path]
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
	_update_camera_orbit(delta)
	_update_input()
	_apply_vehicle(delta)
	_update_camera(delta)
	_update_overlay()
	_write_config()

func _update_input():
	var pads = Input.get_connected_joypads()
	if pads.size() == 0:
		gear = 0
		steer = 0.0
		throttle = 0.0
		right_f1 = Vector2.ZERO
		right_f2 = Vector2.ZERO
		right_two_fingers = false
		return
	var pad = pads[0]
	steer = Input.get_joy_axis(pad, JOY_AXIS_LEFT_X)
	if abs(steer) < 0.05:
		steer = 0.0
	right_touch_active = Input.is_joy_button_pressed(pad, JOY_BUTTON_START)
	left_touch_active = Input.is_joy_button_pressed(pad, JOY_BUTTON_LEFT_STICK)
	right_two_fingers = Input.is_joy_button_pressed(pad, JOY_BUTTON_RIGHT_SHOULDER)
	if right_touch_active:
		throttle = clamp(Input.get_joy_axis(pad, JOY_AXIS_LEFT_Y), -1.0, 1.0)
	gear = _read_gear(pad)
	right_f1 = Vector2(
		Input.get_joy_axis(pad, JOY_AXIS_RIGHT_X),
		Input.get_joy_axis(pad, JOY_AXIS_RIGHT_Y)
	)
	right_f2 = Vector2(
		_axis_to_signed(Input.get_joy_axis(pad, JOY_AXIS_TRIGGER_LEFT)),
		_axis_to_signed(Input.get_joy_axis(pad, JOY_AXIS_TRIGGER_RIGHT))
	)

func _apply_vehicle(_delta):
	if abs(steer) < 0.01 and not left_touch_active:
		steer_angle = lerp(steer_angle, 0.0, clamp(vehicle_settings.steer_return_rate * _delta, 0.0, 1.0))
	else:
		steer_angle += steer * vehicle_settings.steer_rate * _delta
	steer_angle = clamp(steer_angle, -vehicle_settings.max_steer, vehicle_settings.max_steer)
	front_left.steering = -steer_angle
	front_right.steering = -steer_angle

	var engine_force = 0.0
	var brake = 0.0
	if Input.is_key_pressed(KEY_SPACE):
		brake = vehicle_settings.max_brake
	if right_touch_active:
		brake_force = max(0.0, brake_force - vehicle_settings.brake_return_rate * _delta)
	else:
		brake_force = min(vehicle_settings.max_brake, brake_force + vehicle_settings.brake_return_rate * _delta)
	brake = max(brake, brake_force)
	if gear > 0:
		var ratio = _gear_ratio(gear)
		engine_force = vehicle_settings.max_engine_force * ratio * throttle
	elif gear < 0:
		engine_force = -vehicle_settings.reverse_force * abs(throttle)
	elif throttle < 0.0:
		engine_force = vehicle_settings.max_engine_force * throttle
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
			return 0.45
		2:
			return 0.65
		3:
			return 0.85
		4:
			return 1.0
		_:
			return 0.5

func _update_camera(delta):
	var pivot = vehicle.global_transform.origin
	var offset = Vector3(0, 0, camera_settings.camera_distance)
	var basis = Basis(Vector3.UP, camera_yaw) * Basis(Vector3.RIGHT, camera_pitch)
	offset = basis * offset
	var target = pivot + offset + Vector3(0, camera_settings.camera_height, 0)
	var current = camera.global_transform.origin
	camera.global_transform.origin = current.lerp(target, clamp(camera_settings.camera_smooth * delta, 0.0, 1.0))
	camera.look_at(pivot, Vector3.UP)

func _update_camera_orbit(delta):
	var yaw_input = 0.0
	var pitch_input = 0.0
	if Input.is_key_pressed(KEY_LEFT):
		yaw_input -= 1.0
	if Input.is_key_pressed(KEY_RIGHT):
		yaw_input += 1.0
	if Input.is_key_pressed(KEY_UP):
		pitch_input -= 1.0
	if Input.is_key_pressed(KEY_DOWN):
		pitch_input += 1.0
	camera_yaw += yaw_input * camera_settings.camera_yaw_speed * delta
	camera_pitch += pitch_input * camera_settings.camera_pitch_speed * delta
	camera_pitch = clamp(camera_pitch, camera_settings.camera_pitch_min, camera_settings.camera_pitch_max)

func _update_overlay():
	if overlay:
		overlay.steer = steer
		overlay.steer_angle = steer_angle
		overlay.gear = gear
		overlay.pads = Input.get_connected_joypads().size()
		overlay.throttle = throttle
		overlay.right_f1 = right_f1
		overlay.right_f2 = right_f2
		overlay.right_touch_active = right_touch_active
		overlay.right_two_fingers = right_two_fingers
		overlay.queue_redraw()

func _read_gear(pad_id):
	if Input.is_joy_button_pressed(pad_id, JOY_BUTTON_BACK):
		return -1
	if Input.is_joy_button_pressed(pad_id, JOY_BUTTON_A):
		return 1
	if Input.is_joy_button_pressed(pad_id, JOY_BUTTON_B):
		return 2
	if Input.is_joy_button_pressed(pad_id, JOY_BUTTON_X):
		return 3
	if Input.is_joy_button_pressed(pad_id, JOY_BUTTON_Y):
		return 4
	return 0

func _axis_to_signed(value):
	if value >= 0.0 and value <= 1.0:
		return value * 2.0 - 1.0
	return value

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
