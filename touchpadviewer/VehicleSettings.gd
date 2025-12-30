extends RigidBody3D

@export var max_engine_force := 9000.0
@export var reverse_force := 4500.0
@export var max_brake := 30.0
@export var max_steer := 0.45
@export var steer_rate := 1.6
@export var steer_return_rate := 2.0

@export var wheel_radius := 0.6
@export var wheel_width := 0.45
@export var wheel_mass := 55.0
@export var wheel_friction := 2.2
@export var wheel_linear_damp := 0.1
@export var wheel_angular_damp := 0.6
@export var wheel_mesh_rotation := Vector3.ZERO
@export var wheel_drive_axis := Vector3(-1, 0, 0)

@export var front_cornering_stiffness := 90.0
@export var rear_cornering_stiffness := 110.0
@export var max_lateral_force := 9000.0

@export var suspension_travel := 0.3
@export var suspension_stiffness := 140.0
@export var suspension_damping := 18.0
