extends Node2D

var steer := 0.0
var steer_angle := 0.0
var gear := 0
var pads := 0

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

	var info_pos = Vector2(view.x * 0.65, view.y * 0.15)
	draw_string(font, info_pos, "gear: " + gear_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 24, gear_color)
