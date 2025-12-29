extends Node2D

var steer := 0.0
var steer_angle := 0.0
var gear := 0
var pads := 0
var throttle := 0.0
var right_f1 := Vector2.ZERO
var right_f2 := Vector2.ZERO
var right_touch_active := false
var right_two_fingers := false
var left_f1 := Vector2.ZERO
var left_touch_active := false
var speed_kmh := 0.0

var font: Font

func _ready():
	font = ThemeDB.fallback_font

func _draw():
	var view = get_viewport_rect().size
	var center = Vector2(view.x * 0.2, view.y * 0.8)
	var radius = 70.0
	var wheel_color = Color(0.12, 0.12, 0.12)
	var rim_color = Color(0.2, 0.2, 0.2)
	var text_color = Color(1, 1, 1)
	var gear_color = Color(1, 0.2, 0.2) if gear < 0 else text_color
	var gear_label = "R" if gear < 0 else str(gear)
	var display_throttle = throttle

	draw_arc(center, radius, 0.0, TAU, 64, rim_color, 10.0)
	draw_arc(center, radius - 10.0, 0.0, TAU, 64, wheel_color, 8.0)
	draw_circle(center, 10.0, rim_color)
	for i in range(3):
		var angle = steer_angle + TAU * (float(i) / 3.0)
		var spoke_end = center + Vector2.RIGHT.rotated(angle) * (radius - 14.0)
		draw_line(center, spoke_end, wheel_color, 6.0)
	if left_touch_active:
		var wheel_rect = Rect2(center - Vector2(radius, radius), Vector2(radius, radius) * 2.0)
		var wheel_dot = _map_finger(left_f1, wheel_rect)
		var offset = (wheel_dot - center)
		if offset.length() > 1.0:
			var hand = offset.normalized() * (radius - 8.0)
			draw_line(center, center + hand, Color(0.9, 0.9, 0.9), 3.0)
		draw_circle(wheel_dot, 5.0, Color(0.2, 0.7, 1.0))

	draw_string(font, center + Vector2(-60, radius + 20), "steer: " + str(steer), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, text_color)
	draw_string(font, center + Vector2(-60, radius + 40), "gear: " + gear_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, gear_color)
	draw_string(font, center + Vector2(-60, radius + 60), "speed: " + str(snapped(speed_kmh, 0.1)) + " km/h", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, text_color)
	draw_string(font, center + Vector2(-60, radius + 80), "pads: " + str(pads), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, text_color)

	# Joystick vector display (steer/throttle)
	var vec_origin = center + Vector2(120, -40)
	var vec_size = Vector2(80, 80)
	var vec_center = vec_origin + vec_size * 0.5
	draw_rect(Rect2(vec_origin, vec_size), Color(0.8, 0.8, 0.8), false, 2.0)
	draw_line(Vector2(vec_center.x, vec_origin.y), Vector2(vec_center.x, vec_origin.y + vec_size.y), Color(0.5, 0.5, 0.5), 1.0)
	draw_line(Vector2(vec_origin.x, vec_center.y), Vector2(vec_origin.x + vec_size.x, vec_center.y), Color(0.5, 0.5, 0.5), 1.0)
	var vx = clamp(steer, -1.0, 1.0)
	var vy = clamp(-display_throttle, -1.0, 1.0)
	var dot = vec_center + Vector2(vx, vy) * (vec_size.x * 0.45)
	draw_circle(dot, 4.0, Color(1, 0.6, 0.2))

	# 2x2 shifter grid on the bottom-right
	var shifter_origin = Vector2(view.x * 0.65, view.y * 0.65)
	var box = Vector2(70, 60)
	var grid_size = Vector2(box.x * 2 + 12, box.y * 2 + 12)
	var grid_rect = Rect2(shifter_origin, grid_size)
	for row in range(2):
		for col in range(2):
			var idx = col * 2 + row + 1
			var pos = shifter_origin + Vector2(col * (box.x + 12), row * (box.y + 12))
			var color = Color(1, 1, 1) if gear == idx else Color(0.6, 0.6, 0.6)
			draw_rect(Rect2(pos, box), color, false, 3.0)
			draw_string(font, pos + Vector2(26, 38), str(idx), HORIZONTAL_ALIGNMENT_LEFT, -1, 18, color)

	var gear_pos = shifter_origin + Vector2(0, box.y * 2 + 24)
	draw_string(font, gear_pos, "shift: " + gear_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, gear_color)

	# Throttle slider next to the shifter
	var slider_pos = shifter_origin + Vector2(box.x * 2 + 20, 0)
	var slider_size = Vector2(14, box.y * 2 + 12)
	var mid = slider_pos.y + slider_size.y * 0.5
	draw_rect(Rect2(slider_pos, slider_size), Color(0.8, 0.8, 0.8), false, 2.0)
	draw_line(Vector2(slider_pos.x, mid), Vector2(slider_pos.x + slider_size.x, mid), Color(0.6, 0.6, 0.6), 2.0)
	var t = clamp(display_throttle, -1.0, 1.0)
	if t > 0.0:
		var h = (slider_size.y * 0.5) * t
		draw_rect(Rect2(Vector2(slider_pos.x, mid - h), Vector2(slider_size.x, h)), Color(0.2, 0.8, 0.2), true)
	elif t < 0.0:
		var h = (slider_size.y * 0.5) * abs(t)
		draw_rect(Rect2(Vector2(slider_pos.x, mid), Vector2(slider_size.x, h)), Color(0.9, 0.4, 0.2), true)

	# Right-side finger positions on top of the shifter grid
	if right_touch_active:
		var f1 = _map_finger(right_f1, grid_rect)
		draw_circle(f1, 5.0, Color(0.2, 0.7, 1.0))
	if right_two_fingers:
		var f2 = _map_finger(right_f2, grid_rect)
		draw_circle(f2, 5.0, Color(1.0, 0.6, 0.2))

func _map_finger(value, rect):
	var u = clamp((value.x + 1.0) * 0.5, 0.0, 1.0)
	var v = clamp((value.y + 1.0) * 0.5, 0.0, 1.0)
	return rect.position + Vector2(u * rect.size.x, v * rect.size.y)
