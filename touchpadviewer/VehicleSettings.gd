extends RigidBody3D

@export var max_engine_force := 14000.0
@export var reverse_force := 4500.0
@export var max_brake := 30.0
@export var max_steer := 1.1
@export var steer_rate := 1.6
@export var steer_return_rate := 2.0
@export var steer_torque := 6500.0
@export var steer_damping := 320.0
@export var steer_torque_limit := 14000.0
@export var rear_steer_ratio := -0.35

@export var wheel_axis_align_torque := 22000.0
@export var wheel_axis_align_damping := 420.0
@export var wheel_upright_torque := 18000.0
@export var wheel_upright_damping := 360.0
@export var wheel_anchor_spring := 42000.0
@export var wheel_anchor_damping := 2800.0
@export var wheel_anchor_force_limit := 120000.0

@export var wheel_radius := 0.6
@export var wheel_width := 0.45
@export var wheel_mass := 55.0
@export var wheel_friction := 3.2
@export var wheel_lateral_grip := 160.0
@export var wheel_longitudinal_grip := 65.0
@export var wheel_grip_force_limit := 26000.0
@export var wheel_linear_damp := 0.1
@export var wheel_angular_damp := 1.4
@export var wheel_mesh_rotation := Vector3.ZERO
@export var wheel_drive_axis := Vector3(-1, 0, 0)

@export var downforce := 220.0

@export var crawl_speed_kmh := 8.0
@export var crawl_torque_multiplier := 1.6
