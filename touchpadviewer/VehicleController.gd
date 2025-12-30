extends "res://VehicleSettings.gd"

const GEAR_MAX_SPEED_KMH := {
	1: 25.0,
	2: 45.0,
	3: 75.0,
	4: 115.0,
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
var _wheel_material
var _wheel_offsets := {}
var _wheel_mesh_centers := {}
var _wheel_anchor_fl
var _wheel_anchor_fr
var _wheel_anchor_rl
var _wheel_anchor_rr
var _wheel_visuals := {}
var _wheel_visual_basis := {}
var _wheel_roll := {}
var _wheel_anchors := {}
var _front_left_joint
var _front_right_joint

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
@export var steering_wheel_path := NodePath("Visuals/SteeringWheel")

var steering_wheel
var steering_wheel_basis
var using_bridge := false
var fallback_notice := ""
var _fallback_view_size := Vector2.ZERO
var _fallback_active_until := 0
var _fallback_steer := 0.0

@export var allow_fallback_on_linux := true
@export var fallback_mouse_sensitivity := 0.008
@export var auto_center_wheel_mesh := true

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
	_cache_wheel_nodes()
	_configure_wheels()
	_apply_wheel_anchor_positions()
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
	_update_wheel_visuals(delta)
	_update_steering_wheel()
	if using_bridge:
		_write_config()

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

func _apply_vehicle(_delta):
	var have_wheels = front_left and front_right and rear_left and rear_right
	if auto_center_steer and abs(steer) < 0.01 and not left_touch_active:
		steer_angle = lerp(steer_angle, 0.0, clamp(steer_return_rate * _delta, 0.0, 1.0))
	else:
		steer_angle += steer * steer_rate * _delta
	steer_angle = clamp(steer_angle, -max_steer, max_steer)
	# Steer by rotating the front anchors so the hinge axis follows.
	if _wheel_anchor_fl:
		var rot = _wheel_anchor_fl.rotation
		rot.y = -steer_angle
		_wheel_anchor_fl.rotation = rot
	if _wheel_anchor_fr:
		var rot = _wheel_anchor_fr.rotation
		rot.y = -steer_angle
		_wheel_anchor_fr.rotation = rot
	if not have_wheels:
		return
	var drive_torque = 0.0
	var brake = 0.0
	if brake_pressed:
		brake = max_brake
	if gear > 0:
		var ratio = _gear_ratio(gear)
		drive_torque = max_engine_force * ratio * throttle
		var speed_kmh = linear_velocity.length() * 3.6
		var max_speed = GEAR_MAX_SPEED_KMH.get(gear, 80.0)
		var limit = clamp(1.0 - (speed_kmh / max_speed), 0.0, 1.0)
		drive_torque *= limit
	elif gear < 0:
		drive_torque = -reverse_force * abs(throttle)
	if brake > 0.0:
		drive_torque = 0.0

	if rear_left:
		var axis = rear_left.global_transform.basis * wheel_drive_axis.normalized()
		rear_left.apply_torque(axis * drive_torque)
	if rear_right:
		var axis = rear_right.global_transform.basis * wheel_drive_axis.normalized()
		rear_right.apply_torque(axis * drive_torque)
	if brake > 0.0:
		_apply_brake_to_wheel(front_left, brake, _delta)
		_apply_brake_to_wheel(front_right, brake, _delta)
		_apply_brake_to_wheel(rear_left, brake, _delta)
		_apply_brake_to_wheel(rear_right, brake, _delta)
	_apply_tire_forces()
	_stabilize_wheel(front_left)
	_stabilize_wheel(front_right)
	_stabilize_wheel(rear_left)
	_stabilize_wheel(rear_right)

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
	front_left = get_node_or_null("WheelRig/Anchors/WheelFrontLeftAnchor/WheelFrontLeft")
	front_right = get_node_or_null("WheelRig/Anchors/WheelFrontRightAnchor/WheelFrontRight")
	rear_left = get_node_or_null("WheelRig/Anchors/WheelRearLeftAnchor/WheelRearLeft")
	rear_right = get_node_or_null("WheelRig/Anchors/WheelRearRightAnchor/WheelRearRight")
	_wheel_visuals.clear()
	_wheel_visual_basis.clear()
	_wheel_roll.clear()
	_wheel_anchors.clear()
	_register_wheel_visual(front_left, "WheelRig/Anchors/WheelFrontLeftAnchor/Visual")
	_register_wheel_visual(front_right, "WheelRig/Anchors/WheelFrontRightAnchor/Visual")
	_register_wheel_visual(rear_left, "WheelRig/Anchors/WheelRearLeftAnchor/Visual")
	_register_wheel_visual(rear_right, "WheelRig/Anchors/WheelRearRightAnchor/Visual")
	if front_left and _wheel_anchor_fl:
		_wheel_anchors[front_left] = _wheel_anchor_fl
	if front_right and _wheel_anchor_fr:
		_wheel_anchors[front_right] = _wheel_anchor_fr
	if rear_left and _wheel_anchor_rl:
		_wheel_anchors[rear_left] = _wheel_anchor_rl
	if rear_right and _wheel_anchor_rr:
		_wheel_anchors[rear_right] = _wheel_anchor_rr
	_wheel_anchor_fl = get_node_or_null("WheelRig/Anchors/WheelFrontLeftAnchor")
	_wheel_anchor_fr = get_node_or_null("WheelRig/Anchors/WheelFrontRightAnchor")
	_wheel_anchor_rl = get_node_or_null("WheelRig/Anchors/WheelRearLeftAnchor")
	_wheel_anchor_rr = get_node_or_null("WheelRig/Anchors/WheelRearRightAnchor")
	if not front_left or not front_right or not rear_left or not rear_right:
		push_warning("Vehicle wheel nodes missing under Vehicle instance.")

func _configure_wheels():
	_wheel_material = PhysicsMaterial.new()
	_wheel_material.friction = wheel_friction
	_wheel_material.bounce = 0.0
	_configure_wheel(front_left)
	_configure_wheel(front_right)
	_configure_wheel(rear_left)
	_configure_wheel(rear_right)
	_store_wheel_offsets()

func _configure_wheel(wheel):
	if not wheel:
		return
	wheel.top_level = false
	wheel.mass = wheel_mass
	wheel.linear_damp = wheel_linear_damp
	wheel.angular_damp = wheel_angular_damp
	wheel.can_sleep = false
	wheel.physics_material_override = _wheel_material
	wheel.add_collision_exception_with(self)
	wheel.contact_monitor = true
	wheel.max_contacts_reported = 4
	var collision = wheel.get_node_or_null("Collision")
	if collision and collision.shape and collision.shape is CylinderShape3D:
		collision.shape.radius = wheel_radius
		collision.shape.height = wheel_width
		collision.rotation = Vector3(0.0, 0.0, PI / 2.0)
	if auto_center_wheel_mesh:
		_center_wheel_mesh(wheel)

func _register_wheel_visual(wheel, visual_path):
	var visual = get_node_or_null(visual_path)
	if not wheel or not visual:
		return
	_wheel_visuals[wheel] = visual
	_wheel_visual_basis[visual] = visual.transform.basis
	_wheel_roll[visual] = 0.0
	if auto_center_wheel_mesh:
		_center_wheel_mesh(visual)

func _update_wheel_visuals(delta):
	for wheel in _wheel_visuals.keys():
		var visual = _wheel_visuals[wheel]
		if not wheel or not visual:
			continue
		var axis_world = wheel.global_transform.basis * wheel_drive_axis.normalized()
		var spin = wheel.angular_velocity.dot(axis_world)
		var roll = _wheel_roll.get(visual, 0.0) + spin * delta
		_wheel_roll[visual] = roll
		var base = _wheel_visual_basis.get(visual, visual.transform.basis)
		var t = visual.transform
		t.basis = base * Basis(Vector3.RIGHT, roll)
		visual.transform = t

func _apply_brake_to_wheel(wheel, brake_strength, delta):
	if not wheel:
		return
	var factor = clamp(brake_strength * delta, 0.0, 1.0)
	wheel.angular_velocity = wheel.angular_velocity.lerp(Vector3.ZERO, factor)

func _apply_tire_forces():
	_apply_tire_force(front_left, _wheel_anchor_fl, front_cornering_stiffness)
	_apply_tire_force(front_right, _wheel_anchor_fr, front_cornering_stiffness)
	_apply_tire_force(rear_left, _wheel_anchor_rl, rear_cornering_stiffness)
	_apply_tire_force(rear_right, _wheel_anchor_rr, rear_cornering_stiffness)

func _apply_tire_force(wheel, anchor, stiffness):
	if not wheel or not anchor:
		return
	if wheel.get_contact_count() == 0:
		return
	var pos = wheel.global_transform.origin
	var fwd = -anchor.global_transform.basis.z
	var right = anchor.global_transform.basis.x
	var vel = wheel.linear_velocity
	var lateral_speed = vel.dot(right)
	var max_force = self.max_lateral_force
	var lateral_force = (-right * lateral_speed * stiffness).limit_length(max_force)
	wheel.apply_force(lateral_force, pos)

func _stabilize_wheel(wheel):
	if not wheel:
		return
	var anchor = _wheel_anchors.get(wheel, null)
	var basis = anchor.global_transform.basis if anchor else wheel.global_transform.basis
	var axis = basis * wheel_drive_axis.normalized()
	wheel.angular_velocity = axis * wheel.angular_velocity.dot(axis)

func _store_wheel_offsets():
	_wheel_offsets.clear()
	var map = {
		front_left: _wheel_anchor_fl,
		front_right: _wheel_anchor_fr,
		rear_left: _wheel_anchor_rl,
		rear_right: _wheel_anchor_rr,
	}
	for wheel in map.keys():
		var anchor = map[wheel]
		if wheel and anchor:
			_wheel_offsets[wheel] = anchor.global_transform.origin - global_transform.origin
		elif wheel:
			_wheel_offsets[wheel] = wheel.global_transform.origin - global_transform.origin

func _apply_wheel_anchor_positions():
	var pairs = [
		[_wheel_anchor_fl, front_left],
		[_wheel_anchor_fr, front_right],
		[_wheel_anchor_rl, rear_left],
		[_wheel_anchor_rr, rear_right],
	]
	for entry in pairs:
		var anchor = entry[0]
		if not anchor:
			continue
		var wheel = entry[1]
		if wheel:
			var wheel_xform = wheel.global_transform
			wheel_xform.origin = anchor.global_transform.origin
			wheel.global_transform = wheel_xform

func _center_wheel_mesh(root):
	if _wheel_mesh_centers.has(root):
		return
	var meshes := []
	_collect_meshes(root, meshes)
	for mesh in meshes:
		var aabb = mesh.get_aabb()
		var center = aabb.position + aabb.size * 0.5
		mesh.position -= center
		mesh.rotation = wheel_mesh_rotation
	_wheel_mesh_centers[root] = true

func _collect_meshes(node, out):
	for child in node.get_children():
		if child is MeshInstance3D:
			out.append(child)
		_collect_meshes(child, out)

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
		_apply_wheel_anchor_positions()
		for wheel in _wheel_offsets.keys():
			if wheel:
				var wheel_xform = wheel.global_transform
				wheel_xform.origin = respawn_position + _wheel_offsets[wheel]
				wheel.global_transform = wheel_xform
				wheel.linear_velocity = Vector3.ZERO
				wheel.angular_velocity = Vector3.ZERO

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
