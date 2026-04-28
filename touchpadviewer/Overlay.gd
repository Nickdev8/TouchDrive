2extends Node2D

signal mode_chosen(mode: int)

enum GameMode { SELECTING = 0, SHIFT = 1, NO_SHIFT = 2 }
var game_mode: int = GameMode.SELECTING

# State pushed by Main each frame
var steer := 0.0
var steer_angle := 0.0
var gear := 0
var throttle := 0.0
var speed_kmh := 0.0
var notice := ""
var brake_pressed := false
var control_mode := 0

var right_f1 := Vector2.ZERO
var right_f2 := Vector2.ZERO
var right_touch_active := false
var right_two_fingers := false
var left_f1 := Vector2.ZERO
var left_touch_active := false

var font: Font
var _btn_shift_rect := Rect2()
var _btn_noshift_rect := Rect2()

func _ready() -> void:
	font = ThemeDB.fallback_font

func _input(event: InputEvent) -> void:
	if game_mode != GameMode.SELECTING:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			game_mode = GameMode.SHIFT
			emit_signal("mode_chosen", GameMode.SHIFT)
			queue_redraw()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			game_mode = GameMode.NO_SHIFT
			emit_signal("mode_chosen", GameMode.NO_SHIFT)
			queue_redraw()

func _draw() -> void:
	var view := get_viewport_rect().size
	match game_mode:
		GameMode.SELECTING:
			_draw_mode_select(view)
		GameMode.SHIFT:
			_draw_hud_shift(view)
		GameMode.NO_SHIFT:
			_draw_hud_noshift(view)

# ── Mode selection screen ─────────────────────────────────────────────────────

func _draw_mode_select(view: Vector2) -> void:
	draw_rect(Rect2(Vector2.ZERO, view), Color(0.06, 0.06, 0.08, 0.92))

	var white := Color(0.95, 0.95, 0.95)
	var dim   := Color(0.65, 0.65, 0.65)

	# Title
	var title := "TOUCH CLIMBER"
	var title_x := view.x * 0.5 - (title.length() * 12)
	draw_string(font, Vector2(title_x, view.y * 0.22), title,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 42, white)

	var sub := "Select control mode"
	var sub_x := view.x * 0.5 - (sub.length() * 6)
	draw_string(font, Vector2(sub_x, view.y * 0.31), sub,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 20, dim)

	# Buttons
	var btn_w := 230.0
	var btn_h := 100.0
	var gap   := 48.0
	var total_w := btn_w * 2.0 + gap
	var btn_y := view.y * 0.44

	var sx := view.x * 0.5 - total_w * 0.5
	var nx := sx + btn_w + gap

	_btn_shift_rect   = Rect2(Vector2(sx, btn_y), Vector2(btn_w, btn_h))
	_btn_noshift_rect = Rect2(Vector2(nx, btn_y), Vector2(btn_w, btn_h))

	# SHIFT button — left click
	draw_rect(_btn_shift_rect, Color(0.12, 0.14, 0.22), true)
	draw_rect(_btn_shift_rect, Color(0.45, 0.55, 0.85), false, 2.0)
	draw_string(font, Vector2(sx + 20, btn_y + 32), "LEFT CLICK",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.6, 0.65, 0.9))
	draw_string(font, Vector2(sx + 20, btn_y + 56), "SHIFT MODE",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(0.85, 0.9, 1.0))
	draw_string(font, Vector2(sx + 20, btn_y + 78), "Manual gear selection",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, dim)

	# NO-SHIFT button — right click
	draw_rect(_btn_noshift_rect, Color(0.10, 0.18, 0.12), true)
	draw_rect(_btn_noshift_rect, Color(0.35, 0.75, 0.45), false, 2.0)
	draw_string(font, Vector2(nx + 16, btn_y + 32), "RIGHT CLICK",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.5, 0.8, 0.55))
	draw_string(font, Vector2(nx + 16, btn_y + 56), "NO-SHIFT MODE",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(0.75, 1.0, 0.8))
	draw_string(font, Vector2(nx + 16, btn_y + 78), "Right side = throttle",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, dim)

	if notice != "":
		draw_string(font, Vector2(20, view.y - 28), notice,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.85, 0.3))

# ── SHIFT mode HUD ────────────────────────────────────────────────────────────

func _draw_hud_shift(view: Vector2) -> void:
	var white     := Color(1, 1, 1)
	var dim       := Color(0.55, 0.55, 0.55)
	var gear_col  := Color(1, 0.25, 0.25) if gear < 0 else white
	var gear_lbl  := "R" if gear < 0 else str(gear)

	# Steering wheel — bottom-left
	_draw_steering_wheel(Vector2(view.x * 0.15, view.y * 0.78), 65.0)

	# Speed — top-center
	var spd_str := str(int(speed_kmh)) + " km/h"
	draw_string(font, Vector2(view.x * 0.5 - 52, 54), spd_str,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 30, white)

	# Gear — below speed
	draw_string(font, Vector2(view.x * 0.5 - 8, 88), gear_lbl,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 26, gear_col)

	# 2×2 gear grid — bottom-right
	var box      := Vector2(62.0, 52.0)
	var box_gap  := 10.0
	var grid_org := Vector2(view.x * 0.73, view.y * 0.70)

	for row in range(2):
		for col in range(2):
			var idx := col * 2 + row + 1
			var pos := grid_org + Vector2(col * (box.x + box_gap), row * (box.y + box_gap))
			var active := gear == idx
			var c := white if active else dim
			var lw := 3.0 if active else 1.5
			draw_rect(Rect2(pos, box), c, false, lw)
			draw_string(font, pos + Vector2(22, 34), str(idx),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 18, c)

	# Finger dots on gear grid
	if right_touch_active:
		var grid_rect := Rect2(grid_org, Vector2(box.x * 2.0 + box_gap, box.y * 2.0 + box_gap))
		draw_circle(_map_finger(right_f1, grid_rect), 5.0, Color(0.2, 0.7, 1.0))
	if right_two_fingers:
		var grid_rect := Rect2(grid_org, Vector2(box.x * 2.0 + box_gap, box.y * 2.0 + box_gap))
		draw_circle(_map_finger(right_f2, grid_rect), 5.0, Color(1.0, 0.6, 0.2))

	# Throttle slider — right of gear grid
	var sl_x    := grid_org.x + box.x * 2.0 + box_gap + 18.0
	var sl_size := Vector2(14.0, box.y * 2.0 + box_gap)
	_draw_throttle_slider(Vector2(sl_x, grid_org.y), sl_size, throttle)

	_draw_brake_indicator(view)

	if notice != "":
		draw_string(font, Vector2(20, 26), notice,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.85, 0.3))

# ── NO-SHIFT mode HUD ─────────────────────────────────────────────────────────

func _draw_hud_noshift(view: Vector2) -> void:
	var white := Color(1, 1, 1)

	# Steering wheel — bottom-left
	_draw_steering_wheel(Vector2(view.x * 0.15, view.y * 0.78), 65.0)

	# Speed — top-center
	var spd_str := str(int(speed_kmh)) + " km/h"
	draw_string(font, Vector2(view.x * 0.5 - 52, 54), spd_str,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 30, white)

	# Auto-gear indicator — below speed
	draw_string(font, Vector2(view.x * 0.5 - 14, 88), "A" + str(gear),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 26, Color(0.7, 0.9, 0.7))

	# Large throttle bar — right edge
	var bar_origin := Vector2(view.x * 0.84, view.y * 0.18)
	var bar_size   := Vector2(40.0, view.y * 0.60)
	_draw_large_throttle_bar(bar_origin, bar_size, throttle, gear)

	_draw_brake_indicator(view)

	if notice != "":
		draw_string(font, Vector2(20, 26), notice,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.85, 0.3))

# ── Shared drawing helpers ────────────────────────────────────────────────────

func _draw_steering_wheel(center: Vector2, radius: float) -> void:
	var wheel_color := Color(0.12, 0.12, 0.12)
	var rim_color   := Color(0.22, 0.22, 0.22)
	draw_arc(center, radius, 0.0, TAU, 64, rim_color, 10.0)
	draw_arc(center, radius - 10.0, 0.0, TAU, 64, wheel_color, 8.0)
	draw_circle(center, 10.0, rim_color)
	var t_angle := steer_angle * 5.0 + (PI * 1.5)
	var t_up    := Vector2.RIGHT.rotated(t_angle)
	var t_right := t_up.rotated(PI * 0.5)
	var t_top    := center + t_up * (radius - 14.0)
	var t_bottom := center - t_up * (radius * 0.3)
	draw_line(t_bottom, t_top, wheel_color, 6.0)
	draw_line(t_top - t_right * (radius * 0.55), t_top + t_right * (radius * 0.55), wheel_color, 6.0)
	if left_touch_active:
		var wheel_rect := Rect2(center - Vector2(radius, radius), Vector2(radius, radius) * 2.0)
		var dot := _map_finger(left_f1, wheel_rect)
		var off := dot - center
		if off.length() > 1.0:
			draw_line(center, center + off.normalized() * (radius - 8.0), Color(0.9, 0.9, 0.9), 3.0)
		draw_circle(dot, 5.0, Color(0.2, 0.7, 1.0))

func _draw_throttle_slider(pos: Vector2, size: Vector2, t_val: float) -> void:
	var mid: float = pos.y + size.y * 0.5
	draw_rect(Rect2(pos, size), Color(0.75, 0.75, 0.75), false, 2.0)
	draw_line(Vector2(pos.x, mid), Vector2(pos.x + size.x, mid), Color(0.55, 0.55, 0.55), 2.0)
	var t: float = clamp(t_val, -1.0, 1.0)
	if t > 0.0:
		var h: float = (size.y * 0.5) * t
		draw_rect(Rect2(Vector2(pos.x, mid - h), Vector2(size.x, h)), Color(0.2, 0.8, 0.2), true)
	elif t < 0.0:
		var h: float = (size.y * 0.5) * abs(t)
		draw_rect(Rect2(Vector2(pos.x, mid), Vector2(size.x, h)), Color(0.9, 0.4, 0.2), true)

func _draw_large_throttle_bar(pos: Vector2, size: Vector2, t_val: float, g: int) -> void:
	var t: float = clamp(t_val, 0.0, 1.0)
	var fwd_h: float = size.y * 0.65
	var neu_h: float = size.y * 0.05
	var rev_h: float = size.y * 0.30
	var neu_y: float = pos.y + fwd_h
	var rev_y: float = neu_y + neu_h

	# Zone backgrounds
	draw_rect(Rect2(pos, Vector2(size.x, fwd_h)), Color(0.08, 0.14, 0.08), true)
	draw_rect(Rect2(Vector2(pos.x, neu_y), Vector2(size.x, neu_h)), Color(0.18, 0.18, 0.18), true)
	draw_rect(Rect2(Vector2(pos.x, rev_y), Vector2(size.x, rev_h)), Color(0.15, 0.08, 0.08), true)

	# Fill — forward fills bottom-up from neutral boundary, reverse fills top-down from neutral
	if g > 0 and t > 0.001:
		var fill_h: float = t * fwd_h
		draw_rect(Rect2(Vector2(pos.x, neu_y - fill_h), Vector2(size.x, fill_h)), Color(0.18, 0.82, 0.35), true)
	elif g < 0 and t > 0.001:
		var fill_h: float = t * rev_h
		draw_rect(Rect2(Vector2(pos.x, rev_y), Vector2(size.x, fill_h)), Color(0.88, 0.35, 0.15), true)

	# Outer border + zone dividers (drawn over fill so they stay crisp)
	draw_rect(Rect2(pos, size), Color(0.45, 0.45, 0.45), false, 2.0)
	draw_line(Vector2(pos.x, neu_y), Vector2(pos.x + size.x, neu_y), Color(0.55, 0.55, 0.55), 1.5)
	draw_line(Vector2(pos.x, rev_y), Vector2(pos.x + size.x, rev_y), Color(0.55, 0.55, 0.55), 1.5)

	# Marker line — sits in the neutral band when throttle is zero
	var marker_y: float
	if g < 0:
		marker_y = rev_y + t * rev_h
	elif t > 0.001:
		marker_y = neu_y - t * fwd_h
	else:
		marker_y = neu_y + neu_h * 0.5  # centred in neutral band when idle
	draw_line(Vector2(pos.x - 5, marker_y), Vector2(pos.x + size.x + 5, marker_y),
		Color(1, 1, 1, 0.95), 2.5)

	# Zone labels
	draw_string(font, Vector2(pos.x - 2, pos.y - 10), "FWD",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.45, 0.8, 0.45))
	draw_string(font, Vector2(pos.x - 2, pos.y + size.y + 16), "REV",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.8, 0.4, 0.3))

	# Percentage readout
	var pct_str := ("R" if g < 0 else "") + str(int(t * 100)) + "%"
	draw_string(font, Vector2(pos.x - 2, pos.y + size.y + 32), pct_str,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1))

func _draw_brake_indicator(view: Vector2) -> void:
	var pos: Vector2 = Vector2(view.x * 0.5 - 28, view.y - 50)
	if brake_pressed:
		draw_rect(Rect2(pos, Vector2(56, 22)), Color(0.88, 0.1, 0.1), true)
		draw_string(font, pos + Vector2(6, 16), "BRAKE",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1))
	else:
		draw_rect(Rect2(pos, Vector2(56, 22)), Color(0.18, 0.18, 0.18), true)
		draw_string(font, pos + Vector2(6, 16), "BRAKE",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.38, 0.38, 0.38))

func _map_finger(value: Vector2, rect: Rect2) -> Vector2:
	var u: float = clamp((value.x + 1.0) * 0.5, 0.0, 1.0)
	var v: float = clamp((value.y + 1.0) * 0.5, 0.0, 1.0)
	return rect.position + Vector2(u * rect.size.x, v * rect.size.y)
