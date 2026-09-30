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
- `Session.join_server(address, port, password, name, fingerprint)` creates a
  `RemoteSession` (`net/remote_session.gd`) as `Session.remote`; the join
  dialog shows its status and `join_failed` reasons. Once joined, Session
  polls it every frame instead of stepping, and the game scene shows
  `remote.world` (a read-only `SimWorld` view) with the build tools sending
  commands through `remote.sink`. If the server drops the game, Session
  returns to the menu, which shows the reason (`disconnect_reason`).
- `Session.leave_to_menu()` leaves the server (if online), drops the world
  and goes back to the menu.

Money is shown as `2 000 000 $`. Settings (window mode, volume, language)
persist to `user://settings.cfg` (`game/settings.gd`). All menu/HUD strings
and build tool strings are in `game/loc.gd` (Czech default, English
included; `Loc.error` translates simulation error texts); add a dictionary there
to translate. `res://main.tscn` is a thin wrapper around `game/game.tscn` for
tools and tests (it starts a throw-away local game if no session exists).

## Layout

- `gameplay/`: camera, ground plane pick (`ground_pick.gd`), build controller
  and overlay, `gameplay_root.gd` (the single entry point `game/game.gd` instances) and
  `command_sink.gd` (where the tools send commands, local or online).
- `net/`: `remote_session.gd` (one visit to a server) and `remote_sink.gd`.
- `ui/`: toolbar, train/line panel, node tooltip. Built in code, no scenes.
- `game/`: session autoload, world generation, settings, strings, the game
  scene (`game.gd`, redraws the network when `gameplay.network_changed`
  fires) and `world_labels.gd` (town, station and train markers and labels).
- `ui/` also has the theme (`ui_theme.gd`), main menu, HUD bar and toast.

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

## Tests

All run headless from the repository root after the build steps above, and
CI runs them on every push. Each prints its OK line and exits non-zero on
failure.

| Test | Checks | Prints |
| --- | --- | --- |
| `tests/smoke_build.gd` | Build tools through a whole line; the train reaches the far station. | `SMOKE OK` |
| `tests/game_loop.gd` | A local game from `Session` with a fixed seed: towns, money, speed control, a line between two towns carries passengers, settings persist. | `GAME LOOP OK` |
| `tests/smoke_net.gd` | `RemoteSession` against a local server: pinned join, the build tools through the remote sink, the train moves, the view is read-only. | `NET SMOKE OK` |
| `tests/online_game.gd` | The real UI path: main menu join dialog, game scene on the remote world, building until the train moves, leaving to the menu, and a server shutdown returning to the menu with the reason. | `ONLINE GAME OK` |

```
godot --headless --path client --script res://tests/game_loop.gd
```

The two online tests start `target/debug/openrail-server` on a free local
port (`tests/test_server.gd`; built with cargo if missing, so run
`cargo build -p openrail-server` first to keep them fast).
