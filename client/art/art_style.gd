class_name ArtStyle
extends Node3D
## Applies OpenRail's painterly look to the scene it is placed in.
##
## Drop art_style.tscn into a scene and it will:
## - take over lighting: its own WorldEnvironment (painted sky, cool ambient,
##   Filmic tonemap, glow, fog) and a warm sun; other WorldEnvironment and
##   DirectionalLight3D nodes in the scene are removed,
## - add the full-screen post-process (paint filter, ink lines, colour grade)
##   to the active camera; on the Mobile and Compatibility renderers only a
##   lighter colour-grade pass,
## - repaint meshes that use a plain StandardMaterial3D with the painterly
##   shader, keeping their colour and albedo texture, including meshes added
##   later and imported glTF models; a material named M_Something is replaced
##   by res://art/materials/M_Something.tres when that file exists,
## - optionally lay a painted ground plane under the world.
## Gameplay code can also ask for materials directly with ArtStyle.paint().
## See docs/art-style.md.

const PAINTERLY_SHADER := preload("res://art/shaders/painterly.gdshader")
# Post-process shaders are loaded on demand: the full one uses the
# normal-roughness buffer, which only exists on Forward+, and fails to compile
# on the Mobile and Compatibility (OpenGL) renderers.
const POST_SHADER_PATH := "res://art/shaders/post_painterly.gdshader"
const POST_SHADER_LITE_PATH := "res://art/shaders/post_painterly_lite.gdshader"
const GROUND_SHADER := preload("res://art/shaders/painterly_ground.gdshader")

## Named colours of the palette, for gameplay code and models.
const PALETTE := {
	"ink": Color(0.12, 0.13, 0.17),
	"brass": Color(0.78, 0.58, 0.28),
	"copper": Color(0.72, 0.36, 0.22),
	"cream": Color(0.93, 0.85, 0.7),
	"teal": Color(0.16, 0.5, 0.48),
	"glow_blue": Color(0.3, 0.75, 0.95),
	"signal_red": Color(0.78, 0.18, 0.14),
	"meadow": Color(0.4, 0.54, 0.32),
	"slate": Color(0.42, 0.49, 0.57),
	"verdigris": Color(0.38, 0.62, 0.54),
	"terracotta": Color(0.78, 0.44, 0.3),
	"soot": Color(0.22, 0.2, 0.24),
}

@export var repaint_standard_materials := true
@export var post_process := true
@export var add_ground := true
@export var ground_size := 20000.0
@export var ground_height := -0.5

const MATERIALS_DIR := "res://art/materials/"

static var _material_cache := {}
var _converted := {}

@onready var _environment: WorldEnvironment = $WorldEnvironment
@onready var _sun: DirectionalLight3D = $Sun
@onready var _rim_light: DirectionalLight3D = $RimLight

var _post_quad: MeshInstance3D


## The post-process shader that works on the current renderer.
static func post_shader_path() -> String:
	if RenderingServer.get_current_rendering_method() == "forward_plus":
		return POST_SHADER_PATH
	return POST_SHADER_LITE_PATH


## Painterly material for a flat colour. Materials are shared per colour.
static func paint(color: Color) -> ShaderMaterial:
	var key := color.to_html()
	if _material_cache.has(key):
		return _material_cache[key]
	var mat := ShaderMaterial.new()
	mat.shader = PAINTERLY_SHADER
	mat.set_shader_parameter("albedo", color)
	mat.set_shader_parameter("alpha_scissor", 0.0)
	_material_cache[key] = mat
	return mat


func _ready() -> void:
	var scene_root := get_parent()
	_remove_competing_lighting(scene_root)
	if add_ground:
		_create_ground()
	if repaint_standard_materials:
		_repaint_tree(scene_root)
		get_tree().node_added.connect(_on_node_added)
	if post_process:
		_attach_post_process.call_deferred()


func _process(_delta: float) -> void:
	# Keep the post-process on whichever camera is active.
	if post_process and _post_quad != null:
		var cam := get_viewport().get_camera_3d()
		if cam != null and _post_quad.get_parent() != cam:
			_post_quad.reparent(cam, false)


func _remove_competing_lighting(scene_root: Node) -> void:
	for node in scene_root.find_children("*", "WorldEnvironment", true, false):
		if node != _environment:
			node.queue_free()
	for node in scene_root.find_children("*", "DirectionalLight3D", true, false):
		if node != _sun and node != _rim_light:
			node.queue_free()


func _create_ground() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(ground_size, ground_size)
	var mat := ShaderMaterial.new()
	mat.shader = GROUND_SHADER
	var ground := MeshInstance3D.new()
	ground.name = "PaintedGround"
	ground.mesh = plane
	ground.material_override = mat
	ground.position = Vector3(0, ground_height, 0)
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)


func _attach_post_process() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		push_warning("ArtStyle: no active Camera3D, post-process not attached")
		return
	var quad := QuadMesh.new()
	quad.size = Vector2(2, 2)
	var mat := ShaderMaterial.new()
	mat.shader = load(post_shader_path())
	_post_quad = MeshInstance3D.new()
	_post_quad.name = "PainterlyPostProcess"
	_post_quad.mesh = quad
	_post_quad.material_override = mat
	_post_quad.extra_cull_margin = 16384.0
	_post_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cam.add_child(_post_quad)


func _repaint_tree(root: Node) -> void:
	if root is MeshInstance3D:
		_repaint(root)
	for child in root.get_children():
		_repaint_tree(child)


func _on_node_added(node: Node) -> void:
	if node is MeshInstance3D and node != _post_quad:
		_repaint(node)


func _repaint(mesh: MeshInstance3D) -> void:
	if mesh.material_override != null:
		var replaced := _painted(mesh.material_override)
		if replaced != null:
			mesh.material_override = replaced
		return
	# Imported models (glTF from openrail-assets) carry materials per surface.
	if mesh.mesh == null:
		return
	for i in mesh.mesh.get_surface_count():
		var source := mesh.get_surface_override_material(i)
		if source == null:
			source = mesh.mesh.surface_get_material(i)
		var replaced := _painted(source)
		if replaced != null:
			mesh.set_surface_override_material(i, replaced)


## The painterly replacement for a material, or null to keep it as is.
func _painted(source: Material) -> Material:
	if source == null:
		return null
	var key := source.get_instance_id()
	if _converted.has(key):
		return _converted[key]
	var result: Material = null
	# 1. A hand-tuned material named like the source (M_Loco_Body -> art/materials/M_Loco_Body.tres).
	if source.resource_name.begins_with("M_"):
		var path := MATERIALS_DIR + source.resource_name + ".tres"
		if ResourceLoader.exists(path):
			result = load(path)
	# 2. Otherwise convert plain StandardMaterial3D, keeping colour and albedo texture.
	if result == null and source is StandardMaterial3D:
		result = _convert_standard(source)
	_converted[key] = result
	return result


func _convert_standard(mat: StandardMaterial3D) -> Material:
	if mat.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED:
		if mat.albedo_color.get_luminance() > 1.0:
			return null # emissive-looking overlays (lamps, UI markers) stay bright
		# Debug lines and overlays: draw them in ink so they sit in the painting.
		var ink := mat.duplicate() as StandardMaterial3D
		ink.albedo_color = PALETTE["ink"]
		return ink
	if mat.albedo_texture == null:
		return paint(mat.albedo_color)
	var textured := ShaderMaterial.new()
	textured.shader = PAINTERLY_SHADER
	textured.resource_name = mat.resource_name
	textured.set_shader_parameter("albedo", mat.albedo_color)
	textured.set_shader_parameter("albedo_texture", mat.albedo_texture)
	textured.set_shader_parameter("use_uv_texture", true)
	# Hand-painted textures already carry their own brushwork.
	textured.set_shader_parameter("value_jitter", 0.1)
	textured.set_shader_parameter("hue_jitter", 0.01)
	if mat.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		textured.set_shader_parameter("alpha_scissor", mat.alpha_scissor_threshold)
	else:
		textured.set_shader_parameter("alpha_scissor", 0.0)
	return textured
