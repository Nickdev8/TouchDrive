# Repository Guidelines

## Project Summary & Current State
- Goal: a touchpad-driven off‑road driving prototype using a Linux multitouch bridge + a Godot 4.5.1 3D vehicle scene.
- Current playable loop: steer on left side of touchpad, shift gears on right side (2x2), throttle by two‑finger scroll on right side, tap to brake.
- HUD shows steering wheel, gear grid, throttle slider, live finger positions, and speed in km/h.
- Vehicle tuning uses per‑gear torque scaling, per‑gear speed caps, and a lowered manual center of mass for stability.
- Obstacles (ramps/steps/bumps) are placed in the scene for testing.

## Project Structure & Module Organization
- `touchpadviewer/` contains the Godot project (project file, scenes, scripts).
- `touchpadviewer/Main.tscn` holds the 3D scene (vehicle, ground, obstacles, lighting).
- `touchpadviewer/Main.gd` owns camera + HUD wiring. Vehicle behavior lives in `VehicleController.gd`.
- `touchpadviewer/Overlay.gd` draws the HUD (steering wheel, gears, throttle, finger dots).
- `touchpadviewer/VehicleSettings.gd` and `touchpadviewer/CameraSettings.gd` store inspector‑tunable settings.
- `touchpadviewer/touchpad_joy_bridge.py` is the Linux MT → virtual joystick bridge (runtime dependency).
- `touchpadviewer/assets/` stores models/textures (sources are ignored).
- `old/` contains legacy or experimental scripts not used by the current app.
- `tools/make_cliff_terrain.py` generates a Blender blockout `.blend` for cliff‑road terrain prototyping.

## Build, Test, and Development Commands
- Run the project in the Godot editor: open `touchpadviewer/project.godot` and press Play.
- The bridge is started automatically by `Main.gd`, but can be run manually:
  - `python3 touchpadviewer/touchpad_joy_bridge.py --auto`
- Optional: generate a terrain blockout `.blend` via Blender:
  - `blender --background --python tools/make_cliff_terrain.py`
- There is no export or automated test pipeline yet.

## Coding Style & Naming Conventions
- GDScript: use tabs for indentation, Godot 4 syntax, and short functions.
- Python: 4-space indentation, minimal dependencies, and direct procedural flow.
- Filenames use `snake_case` for Python and `PascalCase` for Godot scenes/scripts.

## Testing Guidelines
- No automated tests are present.
- When changing input behavior, validate by running the scene and verifying:
  - steering wheel response, gear selection, throttle slider movement
  - vehicle movement and wheel steering in 3D

## Commit & Pull Request Guidelines
- No established commit message convention in history yet.
- Use clear, imperative messages (e.g., "Add shifter gating", "Fix bridge config reload").
- PRs should include a short description, reproduction steps, and a screenshot or short clip when UI/input behavior changes.

## Configuration & Runtime Notes
- Live tuning is driven by `user://touchpad_joy_config.json`, written by `VehicleController.gd`.
- The bridge writes HUD state to `user://touchpad_joy_state.json` for left‑pad finger visualization.
- Adjust tuning via exported fields in the `Vehicle` node inspector; the bridge reloads the JSON periodically.
- Linux input access may require permissions for `/dev/input/event*` and `/dev/uinput`.

## Custom Wheel Physics (RigidBody + Hinge)
- Vehicle is now a `RigidBody3D` chassis with 4 `RigidBody3D` wheels, each constrained by a `HingeJoint3D`.
- Wheel placement is driven by anchor nodes under `WheelRig/Anchors` (move these to reposition wheels).
- Front wheels steer by rotating the front anchor nodes on Y each frame.
- Drive torque is applied to the rear wheel bodies; brakes damp the wheel angular velocity.
- Wheel collision uses a `CylinderShape3D` rotated to roll on the X axis.

### Tuning
- Chassis + wheel parameters live on the `Vehicle` node via `VehicleSettings.gd` exports:
  - `max_engine_force`, `reverse_force`, `max_brake`, `max_steer`, `steer_rate`, `steer_return_rate`
  - `wheel_radius`, `wheel_width`, `wheel_mass`, `wheel_friction`, `wheel_linear_damp`, `wheel_angular_damp`
  - `suspension_travel`, `suspension_stiffness`, `suspension_damping` (reserved if re-adding spring joints)
- Mesh alignment:
  - `wheel_mesh_rotation` in `VehicleSettings.gd` lets you align the visual wheel axle.
  - `auto_center_wheel_mesh` in `VehicleController.gd` recenters wheel meshes at runtime.

### Control Logic
- `VehicleController.gd` handles input, gear logic, torque, braking, and steering pivot rotation.
- Linux uses the touchpad bridge; Windows/macOS fall back to mouse controls.

## Next Features (Planned)
- Larger off‑road test area (cliffs, uneven terrain, rock garden).
- Export workflow for Linux builds with bundled bridge.
- Tuning presets for steering/throttle/gear sensitivity and camera.
