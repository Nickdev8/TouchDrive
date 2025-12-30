extends RigidBody3D

@export var max_engine_force := 9000.0
@export var reverse_force := 4500.0
@export var max_brake := 30.0
@export var max_steer := 0.85
@export var steer_rate := 1.6
@export var steer_return_rate := 2.0
@export var steer_torque := 3800.0
@export var steer_damping := 240.0
@export var steer_torque_limit := 9000.0

@export var wheel_axis_align_torque := 22000.0
@export var wheel_axis_align_damping := 420.0
@export var wheel_anchor_spring := 42000.0
@export var wheel_anchor_damping := 2800.0
@export var wheel_anchor_force_limit := 120000.0

@export var wheel_radius := 0.6
@export var wheel_width := 0.45
@export var wheel_mass := 55.0
@export var wheel_friction := 2.2
@export var wheel_lateral_grip := 120.0
@export var wheel_longitudinal_grip := 40.0
@export var wheel_grip_force_limit := 18000.0
@export var wheel_linear_damp := 0.1
@export var wheel_angular_damp := 1.4
@export var wheel_mesh_rotation := Vector3.ZERO
@export var wheel_drive_axis := Vector3(-1, 0, 0)

@export var downforce := 120.0
