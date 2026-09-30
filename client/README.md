# OpenRail Godot client

Requires Godot 4.4+ and the `openrail-gdext` library built with
`cargo build -p openrail-gdext` copied to `client/bin/` (see "Building and
smoke test" below).

## Controls

Camera (`gameplay/rts_camera.gd`)

| Input | Action |
| --- | --- |
| WASD / arrow keys | Pan (Shift = faster) |
| Mouse to window edge | Pan |
| Mouse wheel | Zoom |
| Middle mouse drag | Rotate and tilt |
| Q / E | Rotate |

Game speed (top bar, `ui/hud.gd`)

| Key | Action |
| --- | --- |
| Space | Pause / resume |
| F1 / F2 / F3 / F4 | Pause / 1x / 2x / 4x |
| + / - | One speed step faster / slower |

The speed keys do nothing on a remote server (the server owns the clock).

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

## Game flow

`project.godot` starts `ui/main_menu.tscn` (new game, join server, settings,
quit). The autoload `Session` (`game/session.gd`) owns the current `SimWorld`:

- `Session.start_local(seed, towns)` generates the world (`game/world_gen.gd`:
  towns from the seed, empty land, 2,000,000 money) and loads
  `game/game.tscn`. In local mode Session steps the sim at 10 ticks per
  second times the speed (0 pause, 1, 2, 4).
- `Session.join_server(...)` loads `res://net/remote_session.gd` if it exists
  (`join(...)`, `poll(delta)`, `world`, `leave()`, signals `status_changed`,
  `joined`, `failed`); otherwise it emits `join_failed` ("Online zatím není
  hotové"). Once joined, Session calls the remote's `poll(delta)` instead of
  stepping and reads its `world`.
- `Session.leave_to_menu()` drops the world and goes back to the menu.

Money is shown as `2 000 000 $`. Settings (window mode, volume, language)
persist to `user://settings.cfg` (`game/settings.gd`). All menu/HUD strings
are in `game/loc.gd` (Czech default, English included); add a dictionary there
to translate. `res://main.tscn` is a thin wrapper around `game/game.tscn` for
tools and tests (it starts a throw-away local game if no session exists).

## Layout

- `gameplay/`: camera, ground plane pick (`ground_pick.gd`), build controller
  and overlay, `gameplay_root.gd` (the single entry point `main.gd` instances).
- `ui/`: toolbar, train/line panel, node tooltip. Built in code, no scenes.
- `game/`: session autoload, world generation, settings, strings, the game
  scene (`game.gd`, redraws the network when `gameplay.network_changed`
  fires) and `world_labels.gd` (town, station and train markers and labels).
- `ui/` also has the theme (`ui_theme.gd`), main menu, HUD bar and toast.

## Tests

`tests/game_loop.gd` starts a game from `Session` with a fixed seed, builds a
line between two towns with the build tools, runs the sim and checks towns,
money and carried passengers (`godot --headless --path client --script
res://tests/game_loop.gd`, prints `GAME LOOP OK`).

## Building and smoke test

The client needs the `openrail-gdext` library inside the project, in
`client/bin/` (ignored by version control; `openrail.gdextension` points there
so exports include it). After every Rust change:

```
cargo build -p openrail-gdext          # add --release for a release build
tools/copy-gdext.sh debug              # or: release (Linux and Windows Git Bash)
```

To make a playable export locally, see `docs/releasing.md`.

A headless test drives the build tools through a whole line (track, stations, train, route) and checks the train reaches the far station. CI runs it on every push:

```
godot --headless --import --path client
godot --headless --path client --script res://tests/smoke_build.gd
```
