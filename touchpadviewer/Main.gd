extends Node2D

# Minimal font reference for drawing text
var font: Font

# Steering wheel state
var steer := 0.0
var wheel_angle := 0.0
var wheel_speed := 3.0
var gear := 0

# Background bridge process id
var bridge_pid := -1
var config_path := ""
var _last_config := {}

# Minimal font reference for drawing text
func _ready():
	# Load the built-in default font
	font = ThemeDB.fallback_font
	# Start the touchpad->joystick bridge so Godot can read joystick input
	var script_path = ProjectSettings.globalize_path("res://touchpad_joy_bridge.py")
	config_path = ProjectSettings.globalize_path("user://touchpad_joy_config.json")
	_write_config()
	bridge_pid = OS.create_process("python3", [script_path, "--auto", "--config", config_path])
	tree_exiting.connect(_on_tree_exiting)

func _exit_tree():
	_stop_bridge()

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_stop_bridge()

func _on_tree_exiting():
	_stop_bridge()

func _stop_bridge():
	# Stop the bridge when the scene exits
	if bridge_pid > 0:
		OS.kill(bridge_pid)
		bridge_pid = -1

func _process(_delta):
	# Read steering from the first connected joystick
	var pads = Input.get_connected_joypads()
	if pads.size() > 0:
		steer = Input.get_joy_axis(pads[0], JOY_AXIS_LEFT_X)
		gear = _read_gear(pads[0])
	else:
		steer = 0.0
		gear = 0
	if abs(steer) < 0.05:
		steer = 0.0
	wheel_angle += steer * wheel_speed * _delta
	_write_config()
	queue_redraw()

func _draw():
	# Draw a simple steering wheel driven by the joystick axis
	var view_size = get_viewport_rect().size
	var center = Vector2(view_size.x * 0.3, view_size.y * 0.5)
	var radius = 120.0
	draw_circle(center, radius, Color.WHITE)
	var hand = Vector2.RIGHT.rotated(wheel_angle) * (radius - 20.0)
	draw_line(center, center + hand, Color.BLACK, 6.0)
	draw_string(font, center + Vector2(-70, radius + 30), "steer: " + str(steer), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
	draw_string(font, center + Vector2(-70, radius + 50), "wheel: " + str(wheel_angle), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
	draw_string(font, center + Vector2(-70, radius + 70), "pads: " + str(Input.get_connected_joypads().size()), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
	var gear_label = "R" if gear < 0 else str(gear)
	var gear_color = Color(1, 0.2, 0.2) if gear < 0 else Color.WHITE
	draw_string(font, center + Vector2(-70, radius + 90), "gear: " + gear_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, gear_color)

	# Draw a simple 2x2 shifter grid on the right side
	var shifter_origin = Vector2(view_size.x * 0.65, view_size.y * 0.35)
	var box = Vector2(80, 70)
	for row in range(2):
		for col in range(2):
			var idx = col * 2 + row + 1
			var pos = shifter_origin + Vector2(col * (box.x + 12), row * (box.y + 12))
			var color = Color.WHITE if gear == idx else Color(0.6, 0.6, 0.6)
			draw_rect(Rect2(pos, box), color, false, 3.0)
			draw_string(font, pos + Vector2(30, 42), str(idx), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, color)

	var shifter_label = "R" if gear < 0 else str(gear)
	var shifter_color = Color(1, 0.2, 0.2) if gear < 0 else Color.WHITE
	draw_string(font, shifter_origin + Vector2(0, box.y * 2 + 24), "shift: " + shifter_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, shifter_color)

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

@export var steer_delta_scale := 0.1
@export var steer_deadzone := 10.0
@export var shift_margin := 0.12
@export var shift_gap := 0.18
@export var neutral_min := 0.45
@export var neutral_max := 0.55
@export var gear_hold_time := 0.12

func _write_config():
	var cfg = {
		"steer_delta_scale": steer_delta_scale,
		"steer_deadzone": steer_deadzone,
		"shift_margin": shift_margin,
		"shift_gap": shift_gap,
		"neutral_min": neutral_min,
		"neutral_max": neutral_max,
		"gear_hold_time": gear_hold_time,
	}
	if cfg == _last_config:
		return
	var file = FileAccess.open(config_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(cfg))
		file.close()
	_last_config = cfg
