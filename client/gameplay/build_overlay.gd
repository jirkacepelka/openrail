extends MeshInstance3D
## Immediate-mode line overlay for the build tools: node markers, hover ring,
## ghost track preview and route draft. Placeholder look; the visuals team
## will restyle. Usage per frame: begin(), line()/ring()/square() calls, end().
##
## Lines are draped over the terrain: the y of the points passed in is
## ignored, long lines are split into short pieces and every vertex sits
## `HEIGHT` metres above the ground (all heights fetched in one batch in end()).

const RING_SEGMENTS := 20
const HEIGHT := 1.5 ## Metres above the ground.
const MAX_PIECE := 12.0 ## Longest straight piece of a draped line, in metres.
const MAX_PIECES := 400 ## Per line, so a huge line cannot stall a frame.

## World whose terrain the lines follow; null draws on the y = 0 plane.
var sim: SimWorld

var _imm := ImmediateMesh.new()
var _points := PackedVector2Array() ## Pairs of line ends, sim metres.
var _colors := PackedColorArray() ## One per pair.


func _ready() -> void:
	mesh = _imm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true
	mat.render_priority = 10
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func begin() -> void:
	_imm.clear_surfaces()
	_points.clear()
	_colors.clear()


func line(a: Vector3, b: Vector3, color: Color) -> void:
	var pa := Vector2(a.x, a.z)
	var pb := Vector2(b.x, b.z)
	var pieces := clampi(ceili(pa.distance_to(pb) / MAX_PIECE), 1, MAX_PIECES)
	if sim == null:
		pieces = 1
	var prev := pa
	for i in range(1, pieces + 1):
		var next := pa.lerp(pb, float(i) / float(pieces))
		_points.append(prev)
		_points.append(next)
		_colors.append(color)
		prev = next


func ring(center: Vector3, radius: float, color: Color) -> void:
	var prev := center + Vector3(radius, 0.0, 0.0)
	for i in range(1, RING_SEGMENTS + 1):
		var ang := TAU * float(i) / float(RING_SEGMENTS)
		var next := center + Vector3(cos(ang), 0.0, sin(ang)) * radius
		line(prev, next, color)
		prev = next


func square(center: Vector3, half: float, color: Color) -> void:
	var c0 := center + Vector3(-half, 0.0, -half)
	var c1 := center + Vector3(half, 0.0, -half)
	var c2 := center + Vector3(half, 0.0, half)
	var c3 := center + Vector3(-half, 0.0, half)
	line(c0, c1, color)
	line(c1, c2, color)
	line(c2, c3, color)
	line(c3, c0, color)


func end() -> void:
	if _points.is_empty():
		return # a surface without vertices is an engine error
	var heights := PackedFloat32Array()
	if sim != null:
		heights = sim.terrain_heights_at(_points)
	_imm.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in _points.size():
		var p := _points[i]
		var y := (heights[i] if sim != null else 0.0) + HEIGHT
		_imm.surface_set_color(_colors[i / 2])
		_imm.surface_add_vertex(Vector3(p.x, y, p.y))
	_imm.surface_end()
