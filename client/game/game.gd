extends Node3D
## The game scene: shows the world held by the `Session` autoload. Sim
## coordinates (x, y) map to Godot's ground plane (x, z) and the terrain
## height is Godot y (world/ground.gd). Stepping the sim is the Session's
## job; this scene draws the terrain, network, towns, stations and trains and
## hosts the build tools and the HUD.
##
## Online (`Session.is_remote()`) the world is the read-only view of
## `Session.remote` and the build tools send their commands through
## `Session.remote.sink`; the server generated the world and runs the clock.

const GameplayRoot := preload("res://gameplay/gameplay_root.gd")
const WorldLabels := preload("res://game/world_labels.gd")
const Terrain := preload("res://world/terrain.gd")
const TrackMesh := preload("res://world/track_mesh.gd")
const RtsCamera := preload("res://gameplay/rts_camera.gd")
const Hud := preload("res://ui/hud.gd")
const Toast := preload("res://ui/toast.gd")
const Loc := preload("res://game/loc.gd")

## The simulation's text for a command it could not afford.
const FUNDS_ERROR := "not enough money"
## Start view: a tycoon-like look at the first town.
const START_DISTANCE := 560.0
const START_PITCH := 0.72 ## Radians above the horizon (about 41 degrees).
const START_YAW := 0.6

var sim: SimWorld
var terrain: Terrain
var track_mesh: TrackMesh
var gameplay: GameplayRoot
var labels: WorldLabels
var hud: Hud
var toast: Toast


func _ready() -> void:
	var session := _session()
	if session != null and session.world == null:
		# Opened directly (editor F6, tools): start a throw-away local game.
		var change: bool = session.change_scenes
		session.change_scenes = false
		session.start_local(1, 6)
		session.change_scenes = change
	sim = session.world if session != null else null
	if sim == null:
		push_error("Game scene needs a Session world")
		return

	var camera := $Camera3D as Camera3D
	if camera is RtsCamera:
		(camera as RtsCamera).sim = sim
		_start_view(camera as RtsCamera)
	terrain = Terrain.new()
	terrain.name = "Terrain"
	add_child(terrain)
	terrain.setup(sim, camera)
	track_mesh = TrackMesh.new()
	track_mesh.name = "Tracks"
	add_child(track_mesh)
	track_mesh.setup(sim)

	labels = WorldLabels.new()
	labels.name = "WorldLabels"
	add_child(labels)
	labels.setup(sim)

	# Gameplay layer: build tools, line panel and RTS camera input.
	gameplay = GameplayRoot.new()
	add_child(gameplay)
	var sink: RefCounted = null
	if session.is_remote() and session.remote != null:
		sink = session.remote.sink
	gameplay.setup(sim, camera, sink)
	gameplay.network_changed.connect(_draw_tracks)
	gameplay.trains_changed.connect(labels.refresh)
	gameplay.controller.command_failed.connect(_on_command_failed)

	var layer := CanvasLayer.new()
	layer.name = "HudLayer"
	layer.layer = 11
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	hud = Hud.new()
	root.add_child(hud)
	hud.setup(session)
	toast = Toast.new()
	root.add_child(toast)


func _session() -> Node:
	return get_node_or_null("/root/Session")


func _draw_tracks() -> void:
	track_mesh.rebuild() # after every change to the network
	labels.refresh()


## Looks at the first town from close up (the map centre without towns).
func _start_view(camera: RtsCamera) -> void:
	var towns := sim.town_positions()
	var at := towns[0] if not towns.is_empty() else Vector2.ZERO
	camera.jump_to(Vector3(at.x, 0.0, at.y), START_YAW, START_PITCH, START_DISTANCE)


## Running out of money shows a toast (other rejections only change the
## hint). Works the same locally and online.
func _on_command_failed(error: String) -> void:
	if error == FUNDS_ERROR:
		toast.show_message(Loc.t("toast.no_money"))
