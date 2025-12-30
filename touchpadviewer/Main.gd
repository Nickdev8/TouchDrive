extends Node3D

@onready var camera := $Camera3D
@onready var overlay := $CanvasLayer/Overlay
@onready var camera_settings := $Camera3D
@onready var vehicle := $Vehicle

var camera_yaw := 0.0
var camera_pitch := -0.4
var _camera_first_person := true
var _c_prev := false

@export var first_person_offset := Vector3(0, 1.2, 0.4)
@export var first_person_anchor_path := NodePath("Vehicle/WheelRig/Anchors/InteriorCameraAnchor")
@export var first_person_look_yaw_scale := 0.35
@export var first_person_look_max_yaw := 0.35
@export var first_person_lateral_offset := 0.2
var _first_person_anchor

func _ready():
	if not vehicle:
		push_warning("Vehicle node missing in Main scene.")
	_first_person_anchor = get_node_or_null(first_person_anchor_path)
	if not _first_person_anchor:
		_first_person_anchor = vehicle.find_child("InteriorCameraAnchor", true, false) if vehicle else null

func _physics_process(delta):
	_handle_camera_toggle()
	if not _camera_first_person:
		_update_camera_orbit(delta)
	_update_camera(delta)
	_update_overlay()

func _update_camera(delta):
	if not vehicle:
		return
	if _camera_first_person:
		if _first_person_anchor:
			var t = camera.global_transform
			var steer_input = 0.0
			if vehicle and "steer_angle" in vehicle and "max_steer" in vehicle:
				if abs(vehicle.max_steer) > 0.0001:
					steer_input = clamp(vehicle.steer_angle / vehicle.max_steer, -1.0, 1.0)
			var yaw = clamp(-steer_input * first_person_look_yaw_scale, -first_person_look_max_yaw, first_person_look_max_yaw)
			var local_basis = _first_person_anchor.global_transform.basis * Basis(Vector3.UP, yaw)
			var lateral = local_basis.x * (steer_input * first_person_lateral_offset)
			t.origin = _first_person_anchor.global_transform.origin + lateral
			t.basis = local_basis
			camera.global_transform = t
		else:
			var base = vehicle.global_transform
			var target_pos = base.origin + base.basis * first_person_offset
			var t = camera.global_transform
			t.origin = target_pos
			t.basis = base.basis
			camera.global_transform = t
	else:
		var pivot = vehicle.global_transform.origin
		var offset = Vector3(0, 0, camera_settings.camera_distance)
		var cam_basis = Basis(Vector3.UP, camera_yaw) * Basis(Vector3.RIGHT, camera_pitch)
		offset = cam_basis * offset
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

func _handle_camera_toggle():
	var c_pressed = Input.is_key_pressed(KEY_C)
	if c_pressed and not _c_prev:
		_camera_first_person = not _camera_first_person
	_c_prev = c_pressed

func _update_overlay():
	if not overlay or not vehicle:
		return
	overlay.steer = vehicle.steer
	overlay.steer_angle = vehicle.steer_angle
	overlay.gear = vehicle.gear
	overlay.pads = Input.get_connected_joypads().size()
	overlay.throttle = vehicle.throttle
	overlay.right_f1 = vehicle.right_f1
	overlay.right_f2 = vehicle.right_f2
	overlay.right_touch_active = vehicle.right_touch_active
	overlay.right_two_fingers = vehicle.right_two_fingers
	overlay.left_f1 = vehicle.left_f1
	overlay.left_touch_active = vehicle.left_finger_active
	overlay.speed_kmh = vehicle.linear_velocity.length() * 3.6
	overlay.notice = vehicle.fallback_notice
	overlay.queue_redraw()
