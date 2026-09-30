extends Node3D
## The game scene: shows the world held by the `Session` autoload. Sim
## coordinates (x, y) map to Godot's ground plane (x, z). Stepping the sim is
## the Session's job; this scene draws the network, towns, stations and
## trains and hosts the build tools and the HUD.
##
## Online (`Session.is_remote()`) the world is the read-only view of
## `Session.remote` and the build tools send their commands through
## `Session.remote.sink`; the server generated the world and runs the clock.

const GameplayRoot := preload("res://gameplay/gameplay_root.gd")
const WorldLabels := preload("res://game/world_labels.gd")
const Hud := preload("res://ui/hud.gd")
const Toast := preload("res://ui/toast.gd")
const Loc := preload("res://game/loc.gd")

## The simulation's text for a command it could not afford.
const FUNDS_ERROR := "not enough money"

var sim: SimWorld
var track_mesh: MeshInstance3D
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

	labels = WorldLabels.new()
	labels.name = "WorldLabels"
	add_child(labels)
	labels.setup(sim)
	_draw_tracks()

	# Gameplay layer: build tools, line panel and RTS camera input.
	gameplay = GameplayRoot.new()
	add_child(gameplay)
	var sink: RefCounted = null
	if session.is_remote() and session.remote != null:
		sink = session.remote.sink
	gameplay.setup(sim, $Camera3D as Camera3D, sink)
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
	if track_mesh != null:
		track_mesh.queue_free() # rebuilt after every change to the network
	var segments := sim.track_segments()
	var mesh := ImmediateMesh.new()
	if not segments.is_empty(): # a surface without vertices is an engine error
		mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		for p in segments:
			mesh.surface_add_vertex(Vector3(p.x, 1.0, p.y))
		mesh.surface_end()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.9, 0.9, 0.9)
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = mat
	add_child(inst)
	track_mesh = inst


## Running out of money shows a toast (other rejections only change the
## hint). Works the same locally and online.
func _on_command_failed(error: String) -> void:
	if error == FUNDS_ERROR:
		toast.show_message(Loc.t("toast.no_money"))
