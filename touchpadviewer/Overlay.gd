extends Node2D

var steer := 0.0
var steer_angle := 0.0
var gear := 0
var pads := 0
var throttle := 0.0

var font: Font

func _ready():
	font = ThemeDB.fallback_font

func _draw():
	var view = get_viewport_rect().size
	var center = Vector2(view.x * 0.2, view.y * 0.8)
	var radius = 70.0
	var wheel_color = Color(1, 1, 1)
	var text_color = Color(1, 1, 1)
	var gear_color = Color(1, 0.2, 0.2) if gear < 0 else text_color
	var gear_label = "R" if gear < 0 else str(gear)

	draw_circle(center, radius, wheel_color)
	var hand = Vector2.RIGHT.rotated(steer_angle) * (radius - 10.0)
	draw_line(center, center + hand, Color(0, 0, 0), 4.0)

	draw_string(font, center + Vector2(-60, radius + 20), "steer: " + str(steer), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, text_color)
	draw_string(font, center + Vector2(-60, radius + 40), "gear: " + gear_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, gear_color)
	draw_string(font, center + Vector2(-60, radius + 60), "pads: " + str(pads), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, text_color)

	# 2x2 shifter grid on the bottom-right
	var shifter_origin = Vector2(view.x * 0.65, view.y * 0.65)
	var box = Vector2(70, 60)
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
	var fill_h = slider_size.y * clamp(throttle, 0.0, 1.0)
	draw_rect(Rect2(slider_pos, slider_size), Color(0.8, 0.8, 0.8), false, 2.0)
	draw_rect(Rect2(slider_pos + Vector2(0, slider_size.y - fill_h), Vector2(slider_size.x, fill_h)), Color(1, 0.6, 0.2), true)
