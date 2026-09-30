extends MeshInstance3D
## Immediate-mode line overlay for the build tools: node markers, hover ring,
## ghost track preview and route draft. Placeholder look; the visuals team
## will restyle. Usage per frame: begin(), line()/ring()/square() calls, end().

const RING_SEGMENTS := 20
const HEIGHT := 1.5 ## Slightly above the ground plane, in metres.

var _imm := ImmediateMesh.new()
var _open := false
var _count := 0


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
	_open = false
	_count = 0


func line(a: Vector3, b: Vector3, color: Color) -> void:
	if not _open:
		_imm.surface_begin(Mesh.PRIMITIVE_LINES)
		_open = true
	_imm.surface_set_color(color)
	_imm.surface_add_vertex(Vector3(a.x, HEIGHT, a.z))
	_imm.surface_set_color(color)
	_imm.surface_add_vertex(Vector3(b.x, HEIGHT, b.z))
	_count += 1


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
	if _open:
		_imm.surface_end()
		_open = false
