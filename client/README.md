# OpenRail Godot client

Requires Godot 4.4+ and the `openrail-gdext` library built with
`cargo build -p openrail-gdext` (see `openrail.gdextension`).

## Controls

Camera (`gameplay/rts_camera.gd`)

| Input | Action |
| --- | --- |
| WASD / arrow keys | Pan (Shift = faster) |
| Mouse to window edge | Pan |
| Mouse wheel | Zoom |
| Middle mouse drag | Rotate and tilt |
| Q / E | Rotate |

Build tools (bottom toolbar, `gameplay/build_controller.gd`)

| Key | Tool | Use |
| --- | --- | --- |
| 1 | Track | Click a free point or an existing node, then click again to build a track. Building chains: the end becomes the next start. Points within the snap radius snap to existing nodes. |
| 2 | Station | Click a node to turn it into a station. |
| 3 | Train | Click a track to place a train. |
| 4 | Route | Click a train (or press "Route" in the train list), click stations in order, then Enter or "Confirm route". Backspace removes the last stop. |
| - | Bulldoze | Placeholder, disabled. |

Esc or right click cancels the current step, then the tool. A ghost line is
shown while placing track (green = valid, red = invalid). Hover a node or
station for a tooltip. The panel at the top right lists trains and their
stops.

## Layout

- `gameplay/`: camera, ground plane pick (`ground_pick.gd`), build controller
  and overlay, `gameplay_root.gd` (the single entry point `main.gd` instances).
- `ui/`: toolbar, train/line panel, node tooltip. Built in code, no scenes.
- `main.gd` redraws the network when `gameplay.network_changed` fires.

## Smoke test

A headless test drives the build tools through a whole line (track, stations, train, route) and checks the train reaches the far station. CI runs it on every push:

```
cargo build -p openrail-gdext
godot --headless --import --path client
godot --headless --path client --script res://tests/smoke_build.gd
```
