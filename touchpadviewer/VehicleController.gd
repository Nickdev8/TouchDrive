extends "res://VehicleSettings.gd"

const GEAR_MAX_SPEED_KMH := {
	1: 25.0,
	2: 45.0,
	3: 75.0,
	4: 140.0,
}

const WHEEL_DEFS := [
	{
		"name": "FrontLeft",
		"anchor_path": "WheelRig/Anchors/WheelFrontLeftAnchor",
		"wheel_path": "WheelRig/Anchors/WheelFrontLeftAnchor/WheelFrontLeft",
		"steer_body_path": "WheelRig/Anchors/WheelFrontLeftAnchor/FrontLeftSteer",
		"steer_joint_path": "WheelRig/Anchors/WheelFrontLeftAnchor/FrontLeftSteerJoint",
		"drive": true,
		"steer": true,
		"rear": false,
	},
	{
		"name": "FrontRight",
		"anchor_path": "WheelRig/Anchors/WheelFrontRightAnchor",
		"wheel_path": "WheelRig/Anchors/WheelFrontRightAnchor/WheelFrontRight",
		"steer_body_path": "WheelRig/Anchors/WheelFrontRightAnchor/FrontRightSteer",
		"steer_joint_path": "WheelRig/Anchors/WheelFrontRightAnchor/FrontRightSteerJoint",
		"drive": true,
		"steer": true,
		"rear": false,
	},
	{
		"name": "RearLeft",
		"anchor_path": "WheelRig/Anchors/WheelRearLeftAnchor",
		"wheel_path": "WheelRig/Anchors/WheelRearLeftAnchor/WheelRearLeft",
		"steer_body_path": "WheelRig/Anchors/WheelRearLeftAnchor/RearLeftSteer",
		"steer_joint_path": "WheelRig/Anchors/WheelRearLeftAnchor/RearLeftSteerJoint",
		"drive": true,
		"steer": true,
		"rear": true,
	},
	{
		"name": "RearRight",
		"anchor_path": "WheelRig/Anchors/WheelRearRightAnchor",
		"wheel_path": "WheelRig/Anchors/WheelRearRightAnchor/WheelRearRight",
		"steer_body_path": "WheelRig/Anchors/WheelRearRightAnchor/RearRightSteer",
		"steer_joint_path": "WheelRig/Anchors/WheelRearRightAnchor/RearRightSteerJoint",
		"drive": true,
		"steer": true,
		"rear": true,
	},
]

class WheelData:
	var name := ""
	var anchor: Node3D
	var wheel: RigidBody3D
	var visual: Node3D
	var steer_body: RigidBody3D
	var steer_joint: HingeJoint3D
	var drive := false
	var steer := false
	var rear := false

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
@export var auto_center_wheel_mesh := true

@export var steering_wheel_path := NodePath("Visuals/SteeringWheel")

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

var steering_wheel
var steering_wheel_basis
var using_bridge := false
var fallback_notice := ""
var _fallback_active_until := 0
var _fallback_steer := 0.0

@export var allow_fallback_on_linux := true
@export var fallback_mouse_sensitivity := 0.008

var _wheels: Array[WheelData] = []

func _ready():
	var os_name = OS.get_name()
	using_bridge = os_name == "Linux"
	if using_bridge:
		# Start the touchpad->joystick bridge so Godot can read joystick input
		var script_path = _ensure_bridge_script("touchpad_joy_bridge.py")
		config_path = ProjectSettings.globalize_path("user://touchpad_joy_config.json")
		state_path = ProjectSettings.globalize_path("user://touchpad_joy_state.json")
		_write_config()
		bridge_pid = _start_bridge(script_path)
		tree_exiting.connect(_on_tree_exiting)
	else:
		fallback_notice = "Touchpad bridge unsupported on %s. Mouse fallback: move mouse to steer, LMB gear down, RMB gear up, wheel throttle, MMB/Space brake." % os_name
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	set_process_input(true)
	_cache_wheels()
	_configure_wheels()
	_place_wheels_at_anchors()
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

func _physics_process(delta):
	_check_respawn()
	if using_bridge:
		_read_bridge_state()
	_update_input()
	_apply_vehicle(delta)
	_update_steering_wheel()
	if using_bridge:
		_write_config()

func _cache_wheels():
	_wheels.clear()
	for entry in WHEEL_DEFS:
		var wheel = _build_wheel(entry)
		if wheel:
			_wheels.append(wheel)
	if _wheels.is_empty():
		push_warning("Vehicle wheel nodes missing under Vehicle instance.")

func _build_wheel(entry):
	var wheel = WheelData.new()
	wheel.name = entry["name"]
	wheel.anchor = get_node_or_null(entry["anchor_path"])
	wheel.wheel = get_node_or_null(entry["wheel_path"])
	wheel.drive = entry["drive"]
	wheel.steer = entry["steer"]
	wheel.rear = entry.get("rear", false)
	if entry["steer_body_path"] != "":
		wheel.steer_body = get_node_or_null(entry["steer_body_path"])
	if entry["steer_joint_path"] != "":
		wheel.steer_joint = get_node_or_null(entry["steer_joint_path"])
	if wheel.wheel:
		wheel.visual = wheel.wheel.get_node_or_null("Visual")
	if not wheel.wheel:
		return null
	if auto_center_wheel_mesh and wheel.visual:
		_center_wheel_mesh(wheel.visual)
	return wheel

func _configure_wheels():
	var material = PhysicsMaterial.new()
	material.friction = wheel_friction
	material.bounce = 0.0
	for wheel in _wheels:
		var body = wheel.wheel
		body.top_level = true
		body.mass = wheel_mass
		body.linear_damp = wheel_linear_damp
		body.angular_damp = wheel_angular_damp
		body.can_sleep = false
		body.physics_material_override = material
		body.add_collision_exception_with(self)
		var collision = body.get_node_or_null("Collision")
		if collision and collision.shape and collision.shape is CylinderShape3D:
			collision.shape.radius = wheel_radius
			collision.shape.height = wheel_width
			collision.rotation = Vector3(0.0, 0.0, PI / 2.0)
		if wheel.steer_body:
			wheel.steer_body.top_level = true
			wheel.steer_body.mass = 5.0
			wheel.steer_body.linear_damp = 6.0
			wheel.steer_body.angular_damp = 6.0
			wheel.steer_body.can_sleep = false
			wheel.steer_body.collision_layer = 0
			wheel.steer_body.collision_mask = 0
			wheel.steer_body.add_collision_exception_with(self)

func _place_wheels_at_anchors():
	for wheel in _wheels:
		if not wheel.anchor:
			continue
		if wheel.steer_body:
			wheel.steer_body.global_transform = wheel.anchor.global_transform
		if wheel.wheel:
			wheel.wheel.global_transform = wheel.anchor.global_transform

func _apply_vehicle(delta):
	if auto_center_steer and abs(steer) < 0.01 and not left_touch_active:
		steer_angle = lerp(steer_angle, 0.0, clamp(steer_return_rate * delta, 0.0, 1.0))
	else:
		steer_angle += steer * steer_rate * delta
	steer_angle = clamp(steer_angle, -max_steer, max_steer)
	_update_steering_bodies()

	var drive_torque = _get_drive_torque()
	var brake = max_brake if brake_pressed else 0.0
	if brake > 0.0:
		drive_torque = 0.0

	var drive_wheels := 0
	for wheel in _wheels:
		if wheel.drive:
			drive_wheels += 1
	var torque_per_wheel = drive_torque / max(drive_wheels, 1)

	for wheel in _wheels:
		_apply_drive_to_wheel(wheel, torque_per_wheel)
		if brake > 0.0:
			_apply_brake_to_wheel(wheel.wheel, brake, delta)
		_stabilize_wheel_spin(wheel)
		_align_wheel_axis(wheel)
		_stabilize_wheel_anchor(wheel)
		_apply_grip_forces(wheel)

	if downforce > 0.0:
		apply_central_force(-global_transform.basis.y * downforce * linear_velocity.length())

func _get_drive_torque():
	var drive_torque = 0.0
	if gear > 0:
		var ratio = _gear_ratio(gear)
		drive_torque = max_engine_force * ratio * throttle
		var speed_kmh = linear_velocity.length() * 3.6
		var max_speed = GEAR_MAX_SPEED_KMH.get(gear, 80.0)
		var limit = clamp(1.0 - (speed_kmh / max_speed), 0.0, 1.0)
		drive_torque *= limit
		if speed_kmh <= self.crawl_speed_kmh:
			var t = 1.0 - clamp(speed_kmh / max(self.crawl_speed_kmh, 0.1), 0.0, 1.0)
			drive_torque *= lerp(1.0, self.crawl_torque_multiplier, t)
	elif gear < 0:
		drive_torque = -reverse_force * abs(throttle)
	return drive_torque

func _update_steering_bodies():
	for wheel in _wheels:
		if not wheel.steer or not wheel.steer_body:
			continue
		var steer_axis = global_transform.basis.y
		var rel = global_transform.basis.inverse() * wheel.steer_body.global_transform.basis
		var current = rel.get_euler().y
		var target = -steer_angle
		if wheel.rear:
			target = target * self.rear_steer_ratio
		var error = target - current
		var ang_vel = wheel.steer_body.angular_velocity.dot(steer_axis)
		var torque = steer_axis * clamp(error * steer_torque - ang_vel * steer_damping, -steer_torque_limit, steer_torque_limit)
		wheel.steer_body.apply_torque(torque)
		wheel.steer_body.angular_velocity = steer_axis * wheel.steer_body.angular_velocity.dot(steer_axis)

func _apply_drive_to_wheel(wheel, torque_per_wheel):
	if not wheel.wheel or not wheel.drive:
		return
	var axis = wheel.wheel.global_transform.basis * wheel_drive_axis.normalized()
	wheel.wheel.apply_torque(axis * torque_per_wheel)

func _stabilize_wheel_spin(wheel):
	if not wheel.wheel:
		return
	var axis = wheel.wheel.global_transform.basis * wheel_drive_axis.normalized()
	wheel.wheel.angular_velocity = axis * wheel.wheel.angular_velocity.dot(axis)

func _align_wheel_axis(wheel):
	if not wheel.wheel:
		return
	var reference = wheel.steer_body if wheel.steer_body else wheel.anchor
	if not reference:
		return
	var desired_axis = reference.global_transform.basis * wheel_drive_axis.normalized()
	var current_axis = wheel.wheel.global_transform.basis * wheel_drive_axis.normalized()
	var axis_error = current_axis.cross(desired_axis)
	var ang_vel = wheel.wheel.angular_velocity
	var damping = ang_vel - desired_axis * ang_vel.dot(desired_axis)
	var torque = axis_error * wheel_axis_align_torque - damping * wheel_axis_align_damping
	wheel.wheel.apply_torque(torque)
	var desired_up = reference.global_transform.basis.y
	var current_up = wheel.wheel.global_transform.basis.y
	var up_error = current_up.cross(desired_up)
	var up_ang_vel = ang_vel - desired_up * ang_vel.dot(desired_up)
	var up_torque = up_error * wheel_upright_torque - up_ang_vel * wheel_upright_damping
	wheel.wheel.apply_torque(up_torque)

func _stabilize_wheel_anchor(wheel):
	return

func _apply_grip_forces(wheel):
	return

func _apply_brake_to_wheel(wheel_body, brake_strength, delta):
	var factor = clamp(brake_strength * delta, 0.0, 1.0)
	wheel_body.angular_velocity = wheel_body.angular_velocity.lerp(Vector3.ZERO, factor)

func _gear_ratio(value):
	match value:
		1:
			return 2.9
		2:
			return 1.8
		3:
			return 1.2
		4:
			return 0.55
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
	if content.strip_edges().is_empty():
		left_finger_active = false
		return
	var parser = JSON.new()
	var err = parser.parse(content)
	if err != OK:
		left_finger_active = false
		return
	var data = parser.data
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

func _read_fallback_input():
	left_touch_active = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	right_touch_active = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	left_finger_active = left_touch_active
	right_two_fingers = false
	left_f1 = Vector2.ZERO
	right_f1 = Vector2.ZERO
	_fallback_steer = lerp(_fallback_steer, 0.0, 0.2)
	steer = _fallback_steer
	brake_pressed = Input.is_key_pressed(KEY_SPACE) or Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE)

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
		var pad_name = Input.get_joy_name(pad).to_lower()
		if pad_name.find("touchpad-virtual-joystick") != -1:
			return pad
	return -1

func _find_controller_pad(pads):
	for pad in pads:
		var pad_name = Input.get_joy_name(pad).to_lower()
		if pad_name.find("touchpad-virtual-joystick") == -1:
			return pad
	return -1

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

func _check_respawn():
	if global_transform.origin.y < respawn_height or Input.is_key_pressed(KEY_R):
		var xform = global_transform
		xform.origin = respawn_position
		global_transform = xform
		rotation = respawn_rotation
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		for wheel in _wheels:
			if wheel.wheel:
				wheel.wheel.linear_velocity = Vector3.ZERO
				wheel.wheel.angular_velocity = Vector3.ZERO
			if wheel.steer_body:
				wheel.steer_body.linear_velocity = Vector3.ZERO
				wheel.steer_body.angular_velocity = Vector3.ZERO

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

func _input(event):
	if using_bridge:
		if not allow_fallback_on_linux:
			return
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	if event is InputEventMouseButton and event.pressed:
		_fallback_active_until = Time.get_ticks_msec() + 300
		if event.button_index == MOUSE_BUTTON_LEFT:
			gear = clamp(gear - 1, 1, 4)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			gear = clamp(gear + 1, 1, 4)
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var delta = 0.08 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -0.08
			throttle = clamp(throttle + delta, -1.0, 1.0)
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

func _center_wheel_mesh(root):
	var meshes := []
	_collect_meshes(root, meshes)
	for mesh in meshes:
		var aabb = mesh.get_aabb()
		var center = aabb.position + aabb.size * 0.5
		mesh.position -= center
		mesh.rotation = wheel_mesh_rotation

func _collect_meshes(node, out):
	for child in node.get_children():
		if child is MeshInstance3D:
			out.append(child)
		_collect_meshes(child, out)
