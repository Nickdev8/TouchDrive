extends Node3D

@onready var camera := $Camera3D
@onready var overlay := $CanvasLayer/Overlay
@onready var camera_settings := $Camera3D
@onready var vehicle := $Vehicle

var camera_yaw := 0.0
var camera_pitch := -0.4

func _ready():
	if not vehicle:
		push_warning("Vehicle node missing in Main scene.")

func _physics_process(delta):
	_update_camera_orbit(delta)
	_update_camera(delta)
	_update_overlay()

func _update_camera(delta):
	if not vehicle:
		return
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
	overlay.queue_redraw()
