extends Node
## Autoload `Session`: owns the current world and drives it.
##
## Local mode: the sim steps here at 10 ticks per second times the game speed.
## Remote mode: a `RemoteSession` (res://net/remote_session.gd) owns the
## world; its `poll(delta)` runs here every frame instead of local stepping
## and the speed is controlled by the server. The world is then a read-only
## view and the build tools send commands through `remote.sink`.

const Loc := preload("res://game/loc.gd")
const Settings := preload("res://game/settings.gd")
const WorldGen := preload("res://game/world_gen.gd")
const UITheme := preload("res://ui/ui_theme.gd")
const RemoteSession := preload("res://net/remote_session.gd")

const MENU_SCENE := "res://ui/main_menu.tscn"
const GAME_SCENE := "res://game/game.tscn"
const TICK_SECONDS := 0.1 ## The sim runs at 10 Hz at 1x.
const SPEEDS: Array[int] = [0, 1, 2, 4] ## 0 = pause
const MAX_STEPS_PER_FRAME := 40

enum Mode { NONE, LOCAL, REMOTE }

## Progress text while connecting ("Connecting...", etc.).
signal status_changed(text: String)
## The world exists and the game scene is (about to be) shown.
signal game_started
## Connecting failed; `reason` is user-facing.
signal join_failed(reason: String)
signal speed_changed(speed: int)
signal left_game
## The online game was lost after joining (kicked, server gone). Session
## returns to the menu; the menu shows `disconnect_reason`.
signal disconnected(reason: String)

var world: SimWorld
var mode := Mode.NONE
var speed := 1
var seed_value := 0
## Tests set this to false: no scene switching, they build the scene themselves.
var change_scenes := true
## The online game while connecting or playing, else null.
var remote: RemoteSession
## Why the last online game ended (shown once by the menu), or "".
var disconnect_reason := ""

var _accumulator := 0.0


func _ready() -> void:
	Settings.load_from_disk()
	Settings.apply()
	get_tree().root.theme = UITheme.make()


func is_remote() -> bool:
	return mode == Mode.REMOTE


## Starts a new single-player game and shows the game scene.
func start_local(seed_value_: int, towns: int) -> void:
	seed_value = seed_value_
	_end_remote()
	world = SimWorld.new()
	WorldGen.generate(world, seed_value, towns)
	mode = Mode.LOCAL
	_accumulator = 0.0
	set_speed(1)
	game_started.emit()
	_goto(GAME_SCENE)


## Connects to a server. The result arrives through `status_changed`,
## `game_started` (success) or `join_failed`.
func join_server(address: String, port: int, password: String, player_name: String,
		fingerprint: String) -> void:
	_end_remote()
	disconnect_reason = ""
	var r := RemoteSession.new()
	remote = r
	r.status_changed.connect(func(text: String) -> void: status_changed.emit(text))
	r.joined.connect(_on_remote_joined.bind(r))
	r.failed.connect(_on_remote_failed.bind(r))
	r.disconnected.connect(_on_remote_disconnected.bind(r))
	r.join(address, port, password, player_name, fingerprint)


## Drops the world (leaving the server if online) and returns to the menu.
func leave_to_menu() -> void:
	_end_remote()
	world = null
	mode = Mode.NONE
	left_game.emit()
	_goto(MENU_SCENE)


## Sets the game speed (0 pause, 1, 2 or 4). Ignored in remote mode.
func set_speed(new_speed: int) -> void:
	if mode == Mode.REMOTE or not SPEEDS.has(new_speed):
		return
	speed = new_speed
	speed_changed.emit(speed)


## Steps the local sim right now, ignoring pause (for tests and scenarios).
func advance_ticks(ticks: int) -> void:
	if world == null or mode == Mode.REMOTE:
		return
	for i in ticks:
		world.step()


func _process(delta: float) -> void:
	if remote != null:
		remote.poll(delta) # may join, fail or disconnect (signals above)
		return
	if mode != Mode.LOCAL or world == null or speed == 0:
		return
	_accumulator += delta * speed
	var steps := 0
	while _accumulator >= TICK_SECONDS - 0.000001 and steps < MAX_STEPS_PER_FRAME:
		_accumulator -= TICK_SECONDS
		world.step()
		steps += 1
	if steps == MAX_STEPS_PER_FRAME:
		_accumulator = 0.0 # cannot keep up: drop the backlog instead of spiralling


func _on_remote_joined(r: RemoteSession) -> void:
	if r != remote:
		return
	mode = Mode.REMOTE
	world = r.world
	speed = 1
	speed_changed.emit(speed)
	game_started.emit()
	_goto(GAME_SCENE)


func _on_remote_failed(reason: String, r: RemoteSession) -> void:
	if r != remote:
		return
	_end_remote()
	join_failed.emit(reason)


func _on_remote_disconnected(reason: String, r: RemoteSession) -> void:
	if r != remote:
		return
	disconnect_reason = reason
	_end_remote()
	world = null
	mode = Mode.NONE
	disconnected.emit(reason)
	left_game.emit()
	_goto(MENU_SCENE)


func _end_remote() -> void:
	if remote == null:
		return
	var r := remote
	remote = null
	r.leave()
	if mode == Mode.REMOTE:
		mode = Mode.NONE


func _goto(path: String) -> void:
	if change_scenes:
		get_tree().change_scene_to_file(path)
