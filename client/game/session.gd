extends Node
## Autoload `Session`: owns the current world and drives it.
##
## Local mode: the sim steps here at 10 ticks per second times the game speed.
## Remote mode: a `RemoteSession` (res://net/remote_session.gd, written by the
## network client job) owns the world; `poll(delta)` replaces local stepping
## and the speed is controlled by the server.

const Loc := preload("res://game/loc.gd")
const Settings := preload("res://game/settings.gd")
const WorldGen := preload("res://game/world_gen.gd")
const UITheme := preload("res://ui/ui_theme.gd")

const MENU_SCENE := "res://ui/main_menu.tscn"
const GAME_SCENE := "res://game/game.tscn"
const REMOTE_SCRIPT := "res://net/remote_session.gd"
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

var world: SimWorld
var mode := Mode.NONE
var speed := 1
var seed_value := 0
## Tests set this to false: no scene switching, they build the scene themselves.
var change_scenes := true

var _remote: Object
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
	if not ResourceLoader.exists(REMOTE_SCRIPT):
		join_failed.emit(Loc.t("join.not_ready"))
		return
	var script: GDScript = load(REMOTE_SCRIPT)
	_remote = script.new()
	if _remote is Node:
		add_child(_remote as Node)
	_remote.connect("status_changed", func(text: String) -> void: status_changed.emit(text))
	_remote.connect("joined", _on_remote_joined)
	_remote.connect("failed", _on_remote_failed)
	_remote.call("join", address, port, password, player_name, fingerprint)


## Drops the world and returns to the main menu.
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
	if mode == Mode.REMOTE:
		if _remote != null:
			_remote.call("poll", delta)
			world = _remote.get("world")
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


func _on_remote_joined() -> void:
	mode = Mode.REMOTE
	world = _remote.get("world")
	speed = 1
	game_started.emit()
	_goto(GAME_SCENE)


func _on_remote_failed(reason: String) -> void:
	_end_remote()
	join_failed.emit(reason)


func _end_remote() -> void:
	if _remote == null:
		return
	if _remote.has_method("leave"):
		_remote.call("leave")
	if _remote is Node:
		(_remote as Node).queue_free()
	_remote = null


func _goto(path: String) -> void:
	if change_scenes:
		get_tree().change_scene_to_file(path)
