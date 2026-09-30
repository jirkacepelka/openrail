extends Node3D
## The game scene: shows the world held by the `Session` autoload. Sim
## coordinates (x, y) map to Godot's ground plane (x, z). Stepping the sim is
## the Session's job; this scene draws the network, towns, stations and
## trains and hosts the build tools and the HUD.

const GameplayRoot := preload("res://gameplay/gameplay_root.gd")
const WorldLabels := preload("res://game/world_labels.gd")
const Hud := preload("res://ui/hud.gd")
const Toast := preload("res://ui/toast.gd")
const Loc := preload("res://game/loc.gd")

var sim: SimWorld
var track_mesh: MeshInstance3D
var gameplay: GameplayRoot
var labels: WorldLabels
var hud: Hud
var toast: Toast

var _errors_seen := 0


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
	_errors_seen = sim.error_count()

	labels = WorldLabels.new()
	labels.name = "WorldLabels"
	add_child(labels)
	labels.setup(sim)
	_draw_tracks()

	# Gameplay layer: build tools, line panel and RTS camera input.
	gameplay = GameplayRoot.new()
	add_child(gameplay)
	gameplay.setup(sim, $Camera3D as Camera3D)
	gameplay.network_changed.connect(_draw_tracks)
	gameplay.controller.hint_changed.connect(_on_hint_changed)

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


## A rejected build command shows a toast; running out of money says so.
func _on_hint_changed(_text: String) -> void:
	var errors := sim.error_count()
	if errors == _errors_seen:
		return
	_errors_seen = errors
	if sim.last_error_is_funds():
		toast.show_message(Loc.t("toast.no_money"))
