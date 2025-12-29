# Repository Guidelines

## Project Structure & Module Organization
- `touchpadviewer/` contains the Godot project (project file, scenes, scripts).
- `touchpadviewer/Main.tscn` and `touchpadviewer/Main.gd` hold the runtime scene and logic.
- `touchpadviewer/touchpad_joy_bridge.py` and `touchpadviewer/touchpad_uinput_bridge.py` are Linux input bridges.
- `old/` contains legacy or experimental scripts not used by the current app.

## Build, Test, and Development Commands
- Run the project in the Godot editor: open `touchpadviewer/project.godot` and press Play.
- Run the bridge manually (optional):
  - `python3 touchpadviewer/touchpad_joy_bridge.py --auto`
  - `python3 touchpadviewer/touchpad_uinput_bridge.py --auto --screen 1920x1080`
- There is no build or automated test pipeline defined yet.

## Coding Style & Naming Conventions
- GDScript: use tabs for indentation, Godot 4 syntax, and short functions.
- Python: 4-space indentation, minimal dependencies, and direct procedural flow.
- Filenames use `snake_case` for Python and `PascalCase` for Godot scenes/scripts.

## Testing Guidelines
- No automated tests are present.
- When changing input behavior, validate by running the scene and verifying on-screen steering/shifter response.

## Commit & Pull Request Guidelines
- No established commit message convention in history yet.
- Use clear, imperative messages (e.g., "Add shifter gating", "Fix bridge config reload").
- PRs should include a short description, reproduction steps, and a screenshot or short clip when UI/input behavior changes.

## Configuration & Runtime Notes
- Live tuning is driven by `user://touchpad_joy_config.json`, written by `Main.gd`.
- Adjust tuning via exported fields in the Node2D inspector; the bridge reloads the JSON periodically.
- Linux input access may require permissions for `/dev/input/event*` and `/dev/uinput`.
