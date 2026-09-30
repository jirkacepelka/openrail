extends Node3D
## Renders the track network on the terrain: a ballast bed, two rails and
## sleepers for every track, following the ground height along its length
## (sampled every `SAMPLE_STEP` metres). Over water the track stays a little
## above the surface. The simulation's tracks are straight 2D segments; only
## the rendering follows the terrain for now.
##
## From far away (camera further than LINES_FROM) the tracks are also drawn
## as thin lines, so the network stays readable on the map.
##
## Materials are plain StandardMaterial3Ds named M_Ballast, M_Rail and
## M_Sleeper: ArtStyle repaints them, and uses art/materials/M_*.tres
## instead once the art team adds those files.

const Ground := preload("res://world/ground.gd")

const SAMPLE_STEP := 10.0 ## Metres between height samples along a track.
const GAUGE := 1.435
const BED_TOP := 0.55 ## Top of the ballast above the ground at the centre line.
const BED_TOP_HALF := 1.9 ## Half width of the ballast top.
const BED_FOOT_HALF := 3.1 ## Half width where the ballast meets the ground.
const BED_FOOT_SINK := 0.35 ## How far the bed's foot goes into the ground.
const SLEEPER_SPACING := 0.65
const SLEEPER_SIZE := Vector3(2.6, 0.14, 0.26)
const RAIL_WIDTH := 0.08
const RAIL_HEIGHT := 0.16
const WATER_CLEARANCE := 1.5 ## Track height above water on crossings.
const LINES_FROM := 1800.0 ## Camera distance from which the map lines show.
const LINES_LIFT := 5.0 ## Map lines float this high over coarse far terrain.

var sim: SimWorld

var _bed: MeshInstance3D
var _rails: MeshInstance3D
var _sleepers: MultiMeshInstance3D
var _lines: MeshInstance3D
var _line_points := PackedVector3Array()
var _water_level := 0.0


func setup(p_sim: SimWorld) -> void:
	sim = p_sim
	_water_level = sim.terrain_water_level()
	_bed = _mesh_node("Ballast", _material("M_Ballast", Color(0.56, 0.53, 0.49)))
	_rails = _mesh_node("Rails", _material("M_Rail", Color(0.33, 0.31, 0.3), 0.6))
	_sleepers = MultiMeshInstance3D.new()
	_sleepers.name = "Sleepers"
	var box := BoxMesh.new()
	box.size = SLEEPER_SIZE
	box.material = _material("M_Sleeper", Color(0.38, 0.29, 0.22))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	_sleepers.multimesh = mm
	_sleepers.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_sleepers)
	var lines_mat := StandardMaterial3D.new()
	lines_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lines_mat.albedo_color = Color(0.2, 0.18, 0.2)
	_lines = _mesh_node("MapLines", lines_mat)
	_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_lines.visible = false
	rebuild()


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var far := cam.global_position.y - Ground.height_at(sim, cam.global_position.x,
			cam.global_position.z) > LINES_FROM * 0.6
	var d: Variant = cam.get("distance")
	if d is float:
		far = d > LINES_FROM
	_lines.visible = far and not _line_points.is_empty()


## Height of the track's centre line on the ground at sim (x, y), before
## the ballast: the terrain, or just above the water on crossings.
func track_base(ground: float) -> float:
	return maxf(ground, _water_level + WATER_CLEARANCE)


## Rebuilds all meshes from the current network.
func rebuild() -> void:
	var segments := sim.track_segments()
	var bed := SurfaceTool.new()
	var rails := SurfaceTool.new()
	bed.begin(Mesh.PRIMITIVE_TRIANGLES)
	rails.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sleepers: Array[Transform3D] = []
	_line_points.clear()
	var any := false
	for i in range(0, segments.size() - 1, 2):
		var a := segments[i]
		var b := segments[i + 1]
		if a.distance_to(b) < 0.5:
			continue
		_add_track(a, b, bed, rails, sleepers)
		any = true
	_bed.mesh = _commit(bed, any)
	_rails.mesh = _commit(rails, any)
	var lines := ImmediateMesh.new()
	if not _line_points.is_empty():
		lines.surface_begin(Mesh.PRIMITIVE_LINES)
		for p in _line_points:
			lines.surface_add_vertex(p)
		lines.surface_end()
	_lines.mesh = lines
	var mm := _sleepers.multimesh
	mm.instance_count = sleepers.size()
	for i in sleepers.size():
		mm.set_instance_transform(i, sleepers[i])


func _commit(st: SurfaceTool, any: bool) -> Mesh:
	if not any:
		return null # a surface without vertices is an engine error
	st.generate_normals()
	return st.commit()


## Adds one straight track from sim point `a` to `b`.
func _add_track(a: Vector2, b: Vector2, bed: SurfaceTool, rails: SurfaceTool,
		sleepers: Array[Transform3D]) -> void:
	var length := a.distance_to(b)
	var dir := (b - a) / length
	var side := Vector2(-dir.y, dir.x) # left of the direction of travel
	var n := maxi(ceili(length / SAMPLE_STEP), 1)
	# Centre, left foot and right foot of the bed at every sample.
	var pts := PackedVector2Array()
	for i in n + 1:
		var c := a.lerp(b, float(i) / float(n))
		pts.append(c)
		pts.append(c + side * BED_FOOT_HALF)
		pts.append(c - side * BED_FOOT_HALF)
	var h := sim.terrain_heights_at(pts)

	var centre: Array[Vector3] = [] # top of the ballast on the centre line
	for i in n + 1:
		var c := pts[i * 3]
		var base := track_base(h[i * 3])
		var top := base + BED_TOP
		centre.append(Vector3(c.x, top, c.y))
		if i == 0:
			continue
		_line_points.append(centre[i - 1] + Vector3(0.0, LINES_LIFT, 0.0))
		_line_points.append(centre[i] + Vector3(0.0, LINES_LIFT, 0.0))
		var c0 := pts[(i - 1) * 3]
		var top0 := centre[i - 1].y
		var s3 := Vector3(side.x, 0.0, side.y)
		# Feet follow the ground beside the track (embankment or cutting).
		var fl0 := _foot(c0 + side * BED_FOOT_HALF, h[(i - 1) * 3 + 1], top0)
		var fr0 := _foot(c0 - side * BED_FOOT_HALF, h[(i - 1) * 3 + 2], top0)
		var fl1 := _foot(c + side * BED_FOOT_HALF, h[i * 3 + 1], top)
		var fr1 := _foot(c - side * BED_FOOT_HALF, h[i * 3 + 2], top)
		var tl0 := centre[i - 1] + s3 * BED_TOP_HALF
		var tr0 := centre[i - 1] - s3 * BED_TOP_HALF
		var tl1 := centre[i] + s3 * BED_TOP_HALF
		var tr1 := centre[i] - s3 * BED_TOP_HALF
		_quad(bed, tl0, tl1, tr1, tr0) # top
		_quad(bed, fl0, fl1, tl1, tl0) # left slope
		_quad(bed, tr0, tr1, fr1, fr0) # right slope
		# Rails: a small box section per piece, on top of the sleepers.
		for r in [GAUGE * 0.5, -GAUGE * 0.5]:
			var off := s3 * float(r)
			var lift := Vector3(0.0, SLEEPER_SIZE.y, 0.0)
			_rail(rails, centre[i - 1] + off + lift, centre[i] + off + lift, s3)

	# Sleepers, evenly spaced along the whole track.
	var count := int(length / SLEEPER_SPACING)
	for k in count:
		var d := (float(k) + 0.5) * SLEEPER_SPACING
		var f := d / length * n
		var i0 := mini(int(f), n - 1)
		var p := centre[i0].lerp(centre[i0 + 1], f - i0)
		var tangent := (centre[i0 + 1] - centre[i0]).normalized()
		var right := -Vector3(side.x, 0.0, side.y)
		var up := right.cross(tangent).normalized()
		if up.y < 0.0:
			up = -up
		var basis := Basis(right, up, right.cross(up).normalized())
		sleepers.append(Transform3D(basis, p + Vector3(0.0, SLEEPER_SIZE.y * 0.5, 0.0)))


func _foot(p: Vector2, ground: float, top: float) -> Vector3:
	var y := minf(track_base(ground) - BED_FOOT_SINK, top - 0.1)
	if ground > top:
		y = ground - BED_FOOT_SINK # cutting: the bed side meets the slope
	return Vector3(p.x, y, p.y)


## Quad a b c d, given counter-clockwise seen from its front side.
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	# Godot's front faces wind clockwise.
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(b)
	st.add_vertex(a)
	st.add_vertex(d)
	st.add_vertex(c)


## A rail from `p0` to `p1` (bottom centre), `s3` pointing sideways.
static func _rail(st: SurfaceTool, p0: Vector3, p1: Vector3, s3: Vector3) -> void:
	var w := s3 * (RAIL_WIDTH * 0.5)
	var up := Vector3(0.0, RAIL_HEIGHT, 0.0)
	_quad(st, p0 + w + up, p1 + w + up, p1 - w + up, p0 - w + up) # top
	_quad(st, p0 + w, p1 + w, p1 + w + up, p0 + w + up) # left
	_quad(st, p0 - w + up, p1 - w + up, p1 - w, p0 - w) # right


func _mesh_node(node_name: String, mat: Material) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.name = node_name
	m.material_override = mat
	add_child(m)
	return m


static func _material(mat_name: String, color: Color, metallic: float = 0.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.resource_name = mat_name
	mat.albedo_color = color
	mat.metallic = metallic
	mat.roughness = 0.9 if metallic == 0.0 else 0.4
	return mat
