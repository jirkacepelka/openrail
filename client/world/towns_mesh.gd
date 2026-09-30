class_name TownsMesh
extends RefCounted
## Turns a `TownsLayout` into a few merged meshes, one surface per material.
##
## Every vertex height comes from `Ground.height_at`: streets, yards and
## fields follow the ground, buildings stand level on a stone foundation that
## reaches down to their lowest corner. Vertices are relative to the town
## centre (x, z) so the town node sits at (centre.x, 0, centre.y).
##
## Materials are plain `StandardMaterial3D`s named `M_town_*` and shared by
## all towns; `ArtStyle` repaints them with the painterly shader, or swaps in
## `art/materials/M_town_*.tres` when the art team provides one.

const Ground := preload("res://world/ground.gd")
const L := preload("res://world/towns_layout.gd")

## Plaster walls (index = layout wall colour), then brick and timber.
const WALLS: Array[Array] = [
	["M_town_wall_cream", Color(0.93, 0.86, 0.72)],
	["M_town_wall_ochre", Color(0.90, 0.77, 0.50)],
	["M_town_wall_white", Color(0.90, 0.89, 0.85)],
	["M_town_wall_salmon", Color(0.88, 0.70, 0.60)],
	["M_town_wall_sage", Color(0.76, 0.80, 0.68)],
	["M_town_wall_grey", Color(0.74, 0.76, 0.77)],
	["M_town_wall_brick", Color(0.62, 0.33, 0.25)],
	["M_town_wall_timber", Color(0.44, 0.33, 0.24)],
]
const ROOFS: Array[Array] = [
	["M_town_roof_terracotta", Color(0.72, 0.35, 0.23)],
	["M_town_roof_red", Color(0.60, 0.25, 0.18)],
	["M_town_roof_brown", Color(0.44, 0.28, 0.21)],
	["M_town_roof_slate", Color(0.35, 0.39, 0.46)],
	["M_town_roof_clay", Color(0.79, 0.47, 0.31)],
]
const SPIRE := ["M_town_roof_copper", Color(0.38, 0.60, 0.52)]
const YARDS: Array[Array] = [
	["M_town_yard_lawn", Color(0.44, 0.58, 0.31)],
	["M_town_yard_garden", Color(0.36, 0.50, 0.27)],
	["M_town_yard_beds", Color(0.50, 0.40, 0.28)],
]
const FIELDS: Array[Array] = [
	["M_town_field_wheat", Color(0.84, 0.73, 0.42)],
	["M_town_field_barley", Color(0.77, 0.73, 0.50)],
	["M_town_field_young", Color(0.55, 0.65, 0.31)],
	["M_town_field_potato", Color(0.34, 0.47, 0.25)],
	["M_town_field_ploughed", Color(0.52, 0.40, 0.29)],
	["M_town_field_rapeseed", Color(0.88, 0.80, 0.30)],
	["M_town_field_meadow", Color(0.58, 0.68, 0.39)],
]
const WINDOW := ["M_town_window", Color(0.20, 0.23, 0.29)]
const DOOR := ["M_town_door", Color(0.36, 0.24, 0.17)]
const FOUNDATION := ["M_town_foundation", Color(0.50, 0.48, 0.45)]
const CHIMNEY := ["M_town_chimney", Color(0.47, 0.31, 0.26)]
const STREETS := {
	L.Street.MAIN: ["M_town_street_main", Color(0.38, 0.38, 0.39)],
	L.Street.RING: ["M_town_street_cobble", Color(0.52, 0.49, 0.45)],
	L.Street.LANE: ["M_town_street_cobble", Color(0.52, 0.49, 0.45)],
	L.Street.ROAD: ["M_town_street_gravel", Color(0.60, 0.55, 0.45)],
}
const SIDEWALK := ["M_town_sidewalk", Color(0.67, 0.65, 0.61)]
const SQUARE := ["M_town_square", Color(0.64, 0.60, 0.53)]

## Heights above the ground of the flat layers, so they never share a plane.
const Y_FIELD := 0.2
const Y_YARD := 0.3
const Y_SIDEWALK := 0.4
const Y_STREET := {L.Street.ROAD: 0.45, L.Street.LANE: 0.5, L.Street.RING: 0.5, L.Street.MAIN: 0.6}
const Y_SQUARE := 0.7

const OVERHANG := 0.45

static var _materials := {}


## One merged mesh: surfaces keyed by material name.
class Surfaces:
	var verts := {} ## name -> PackedVector3Array
	var norms := {} ## name -> PackedVector3Array
	var colours := {} ## name -> Color

	func tri(m: Array, a: Vector3, b: Vector3, c: Vector3, n := Vector3.ZERO) -> void:
		var name: String = m[0]
		if not verts.has(name):
			verts[name] = PackedVector3Array()
			norms[name] = PackedVector3Array()
			colours[name] = m[1]
		var geo := (b - a).cross(c - a)
		if n == Vector3.ZERO:
			n = geo.normalized()
			if n.y < 0.0 and absf(n.y) > 0.5:
				n = -n
		# Godot's front faces wind clockwise seen from the front.
		if geo.dot(n) > 0.0:
			var t := b
			b = c
			c = t
		var vs: PackedVector3Array = verts[name]
		vs.append(a)
		vs.append(b)
		vs.append(c)
		var ns: PackedVector3Array = norms[name]
		ns.append(n)
		ns.append(n)
		ns.append(n)

	## Quad a-b-c-d (in order around its edge).
	func quad(m: Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n := Vector3.ZERO) -> void:
		if n == Vector3.ZERO:
			n = (c - a).cross(d - b).normalized()
			if n.y < 0.0:
				n = -n
		tri(m, a, b, c, n)
		tri(m, a, c, d, n)

	func vertex_count() -> int:
		var total := 0
		for name: String in verts:
			total += (verts[name] as PackedVector3Array).size()
		return total

	func to_mesh() -> ArrayMesh:
		var mesh := ArrayMesh.new()
		var names: Array = verts.keys()
		names.sort()
		for name: String in names:
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = verts[name]
			arrays[Mesh.ARRAY_NORMAL] = norms[name]
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(mesh.get_surface_count() - 1, TownsMesh.material(name, colours[name]))
		return mesh


var sim: SimWorld
var origin := Vector2.ZERO
var flat := Surfaces.new() ## streets, square, yards, fields: always drawn
var buildings := Surfaces.new() ## near and middle distance
var details := Surfaces.new() ## windows, doors, chimneys: near only
var cluster := Surfaces.new() ## far: one box per building


## Shared material for a name (created on first use).
static func material(name: String, colour: Color) -> StandardMaterial3D:
	if _materials.has(name):
		return _materials[name]
	var mat := StandardMaterial3D.new()
	mat.resource_name = name
	mat.albedo_color = colour
	mat.roughness = 1.0
	_materials[name] = mat
	return mat


## Builds all meshes for `layout`. Heights come from `p_sim` (may be null).
static func build(layout: Dictionary, p_sim: SimWorld) -> TownsMesh:
	var m := TownsMesh.new()
	m.sim = p_sim
	m.origin = layout["center"]
	m._build(layout)
	return m


func _build(layout: Dictionary) -> void:
	for f: Dictionary in layout["fields"]:
		_flat_rect(FIELDS[f["colour"]], f, Y_FIELD, 30.0)
	for y: Dictionary in layout["yards"]:
		_flat_rect(YARDS[y["colour"]], y, Y_YARD, 12.0)
	for s: Dictionary in layout["streets"]:
		var kind: int = s["kind"]
		var hw: float = s["half_width"]
		_ribbon(STREETS[kind], s["points"], hw, Y_STREET[kind])
		if kind == L.Street.MAIN or kind == L.Street.RING:
			_ribbon(SIDEWALK, s["points"], hw + L.SIDEWALK, Y_SIDEWALK)
	_flat_rect(SQUARE, layout["square"], Y_SQUARE, 10.0)
	for b: Dictionary in layout["buildings"]:
		_building(b)


# --- helpers -------------------------------------------------------------------

func _h(p: Vector2) -> float:
	return Ground.height_at(sim, p.x, p.y)


## Local 3D point for world 2D point `p` at height `y`.
func _v(p: Vector2, y: float) -> Vector3:
	return Vector3(p.x - origin.x, y, p.y - origin.y)


func _flat_rect(m: Array, r: Dictionary, lift: float, step: float) -> void:
	var size: Vector2 = r["size"]
	var a: float = r["angle"]
	var ax := Vector2(cos(a), sin(a))
	var ay := Vector2(-sin(a), cos(a))
	var nx := maxi(ceili(size.x / step), 1)
	var ny := maxi(ceili(size.y / step), 1)
	var base: Vector2 = (r["pos"] as Vector2) - ax * size.x * 0.5 - ay * size.y * 0.5
	var rows: Array[PackedVector3Array] = []
	for j in ny + 1:
		var row := PackedVector3Array()
		for i in nx + 1:
			var p := base + ax * (size.x * i / nx) + ay * (size.y * j / ny)
			row.append(_v(p, _h(p) + lift))
		rows.append(row)
	for j in ny:
		for i in nx:
			flat.quad(m, rows[j][i], rows[j][i + 1], rows[j + 1][i + 1], rows[j + 1][i])


## Street ribbon `hw` metres either side of the polyline, resampled so it
## follows the ground.
func _ribbon(m: Array, points: PackedVector2Array, hw: float, lift: float) -> void:
	var pts := PackedVector2Array()
	for i in points.size() - 1:
		var a := points[i]
		var b := points[i + 1]
		var n := maxi(ceili(a.distance_to(b) / 8.0), 1)
		for k in n:
			pts.append(a.lerp(b, float(k) / n))
	pts.append(points[points.size() - 1])
	var left := PackedVector3Array()
	var right := PackedVector3Array()
	for i in pts.size():
		var d_in := (pts[i] - pts[maxi(i - 1, 0)]).normalized()
		var d_out := (pts[mini(i + 1, pts.size() - 1)] - pts[i]).normalized()
		if i == 0:
			d_in = d_out
		if i == pts.size() - 1:
			d_out = d_in
		var dir := (d_in + d_out).normalized()
		if dir == Vector2.ZERO:
			dir = d_out
		var perp := Vector2(-dir.y, dir.x)
		var miter := 1.0 / maxf(perp.dot(Vector2(-d_out.y, d_out.x)), 0.5)
		var pl := pts[i] + perp * hw * miter
		var pr := pts[i] - perp * hw * miter
		left.append(_v(pl, _h(pl) + lift))
		right.append(_v(pr, _h(pr) + lift))
	for i in pts.size() - 1:
		flat.quad(m, left[i], left[i + 1], right[i + 1], right[i])
	# Round-ish caps hide the seams where streets meet.
	for end in [0, pts.size() - 1]:
		var c := pts[end]
		var cy := _h(c) + lift
		var prev := _v(c + Vector2(hw, 0), cy)
		for k in range(1, 9):
			var q := c + Vector2.from_angle(TAU * k / 8.0) * hw
			var cur := _v(q, cy)
			flat.tri(m, _v(c, cy), prev, cur, Vector3.UP)
			prev = cur


# --- buildings -----------------------------------------------------------------

func _building(b: Dictionary) -> void:
	var kind: int = b["kind"]
	var size: Vector2 = b["size"]
	var a: float = b["angle"]
	var ax := Vector2(cos(a), sin(a))
	var ay := Vector2(-sin(a), cos(a))
	var pos: Vector2 = b["pos"]
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var c2 := [pos - ax * hx - ay * hy, pos + ax * hx - ay * hy, pos + ax * hx + ay * hy, pos - ax * hx + ay * hy]
	var hmin := INF
	var hmax := -INF
	for p: Vector2 in c2:
		var h := _h(p)
		hmin = minf(hmin, h)
		hmax = maxf(hmax, h)
	var floor_y := hmax + 0.35
	var top: float = floor_y + float(b["wall_height"])
	var wall_i: int = b["wall"]
	var wall_m: Array = WALLS[wall_i]
	if kind == L.Kind.CHURCH:
		wall_m = ["M_town_wall_church", Color(0.94, 0.90, 0.80)]
	var roof_i: int = b["roof_colour"]
	var roof_m: Array = SPIRE if roof_i < 0 else ROOFS[roof_i]

	# Foundation plinth down to the lowest corner, then the walls.
	_box_sides(buildings, FOUNDATION, c2, hmin - 0.8, floor_y, 0.12)
	_box_sides(buildings, wall_m, c2, floor_y, top, 0.0)

	# Roof.
	var ridge_x: bool = b["ridge_x"]
	var span := size.y if ridge_x else size.x
	var run := size.x if ridge_x else size.y
	var pitch: float = b["pitch"]
	var rise := span * 0.5 * tan(pitch)
	var hip: bool = b["roof"] == L.Roof.HIP
	# Roof frame: u along the ridge, w across it.
	var u := ax if ridge_x else ay
	var w := ay if ridge_x else -ax
	var o := OVERHANG if kind != L.Kind.CHURCH or roof_i >= 0 else 0.0
	var hu := run * 0.5 + o
	var hw := span * 0.5 + o
	var eave := top - o * tan(pitch)
	var ridge_half := maxf(hu - hw, 0.0) if hip else hu
	var r0 := _v(pos - u * ridge_half, top + rise)
	var r1 := _v(pos + u * ridge_half, top + rise)
	var e := [
		_v(pos - u * hu - w * hw, eave), _v(pos + u * hu - w * hw, eave),
		_v(pos + u * hu + w * hw, eave), _v(pos - u * hu + w * hw, eave),
	]
	var wv := Vector3(w.x, 0, w.y)
	var uv := Vector3(u.x, 0, u.y)
	if hip:
		if ridge_half > 0.01:
			buildings.quad(roof_m, e[0], e[1], r1, r0, _slope_normal(-wv, pitch))
			buildings.quad(roof_m, e[3], e[2], r1, r0, _slope_normal(wv, pitch))
		else:
			buildings.tri(roof_m, e[0], e[1], r0, _slope_normal(-wv, pitch))
			buildings.tri(roof_m, e[3], e[2], r0, _slope_normal(wv, pitch))
		buildings.tri(roof_m, e[0], e[3], r0, _slope_normal(-uv, pitch))
		buildings.tri(roof_m, e[1], e[2], r1, _slope_normal(uv, pitch))
		# Soffit so the overhang does not show the sky from below.
		buildings.quad(roof_m, e[0], e[1], e[2], e[3], Vector3.DOWN)
	else:
		buildings.quad(roof_m, e[0], e[1], r1, r0, _slope_normal(-wv, pitch))
		buildings.quad(roof_m, e[3], e[2], r1, r0, _slope_normal(wv, pitch))
		# Gable ends in the wall colour, flush with the walls.
		var ghu := run * 0.5
		var ghw := span * 0.5
		for sgn: float in [-1.0, 1.0]:
			var g0 := _v(pos + u * ghu * sgn - w * ghw, top)
			var g1 := _v(pos + u * ghu * sgn + w * ghw, top)
			var g2 := _v(pos + u * ghu * sgn, top + rise)
			buildings.tri(wall_m, g0, g1, g2, uv * sgn)
		# Undersides of the overhang.
		buildings.quad(roof_m, e[0], e[1], _v(pos + u * hu, top + rise - 0.05),
				_v(pos - u * hu, top + rise - 0.05), Vector3.DOWN)
		buildings.quad(roof_m, e[3], e[2], _v(pos + u * hu, top + rise - 0.05),
				_v(pos - u * hu, top + rise - 0.05), Vector3.DOWN)

	_openings(b, kind, pos, ax, ay, hx, hy, floor_y)
	if kind in [L.Kind.HOUSE, L.Kind.ROW, L.Kind.APARTMENT, L.Kind.HALL]:
		var cpos := pos + u * run * 0.22 + w * span * 0.12
		var cbase := top + rise * 0.55
		var cc := [cpos + Vector2(-0.35, -0.35), cpos + Vector2(0.35, -0.35),
				cpos + Vector2(0.35, 0.35), cpos + Vector2(-0.35, 0.35)]
		_box_sides(details, CHIMNEY, cc, cbase, top + rise + 0.9, 0.0)
		details.quad(CHIMNEY, _v(cc[0], top + rise + 0.9), _v(cc[1], top + rise + 0.9),
				_v(cc[2], top + rise + 0.9), _v(cc[3], top + rise + 0.9), Vector3.UP)

	# Far: a box to half the roof with a roof-coloured top (spires stay pointed).
	var lod_top := top + rise * 0.5
	_box_sides(cluster, wall_m, c2, hmin, lod_top, 0.0)
	if roof_i < 0:
		var apex := _v(pos, top + rise)
		for i in 4:
			var mid: Vector2 = (c2[i] + c2[(i + 1) % 4]) * 0.5 - pos
			var out := Vector3(mid.x, 0, mid.y).normalized()
			cluster.tri(roof_m, _v(c2[i], lod_top), _v(c2[(i + 1) % 4], lod_top), apex,
					_slope_normal(out, pitch))
	else:
		cluster.quad(roof_m, _v(c2[0], lod_top), _v(c2[1], lod_top), _v(c2[2], lod_top),
				_v(c2[3], lod_top), Vector3.UP)


static func _slope_normal(outward: Vector3, pitch: float) -> Vector3:
	return (outward * sin(pitch) + Vector3.UP * cos(pitch)).normalized()


## Four vertical sides of the prism over corners `c` (CCW), grown by `grow`.
func _box_sides(s: Surfaces, m: Array, c: Array, y0: float, y1: float, grow: float) -> void:
	var center: Vector2 = (c[0] + c[2]) * 0.5
	for i in 4:
		var p0: Vector2 = c[i]
		var p1: Vector2 = c[(i + 1) % 4]
		if grow > 0.0:
			p0 += (p0 - center).normalized() * grow
			p1 += (p1 - center).normalized() * grow
		var mid := (p0 + p1) * 0.5 - center
		var n := Vector3(mid.x, 0, mid.y).normalized()
		s.quad(m, _v(p0, y0), _v(p1, y0), _v(p1, y1), _v(p0, y1), n)


## Windows and doors as dark panels just in front of the walls.
func _openings(b: Dictionary, kind: int, pos: Vector2, ax: Vector2, ay: Vector2,
		hx: float, hy: float, floor_y: float) -> void:
	var floors: int = b["floors"]
	var wall_h: float = b["wall_height"]
	var fh := wall_h / floors
	var win := Vector2(1.1, 1.4)
	var spacing := 3.0
	var sill := 0.9
	match kind:
		L.Kind.APARTMENT, L.Kind.HALL:
			win = Vector2(1.3, 1.7)
			spacing = 3.2
		L.Kind.BARN:
			win = Vector2(0.8, 0.8)
			spacing = 6.0
			sill = fh * 0.55
		L.Kind.WORKSHOP:
			win = Vector2(2.2, 1.8)
			spacing = 4.5
			sill = 1.4
		L.Kind.CHURCH:
			if hx == hy: # tower: one belfry opening per side near the top
				fh = wall_h
				win = Vector2(1.4, 2.6)
				sill = wall_h - 5.0
				spacing = 100.0
			else:
				win = Vector2(1.6, 4.2)
				sill = 2.0
				spacing = 4.5
	# Walls: front (-y), back (+y), sides (-x, +x) as (centre, along, normal, length).
	var walls := [
		[pos - ay * hy, ax, -ay, hx * 2.0, true],
		[pos + ay * hy, -ax, ay, hx * 2.0, false],
		[pos - ax * hx, -ay, -ax, hy * 2.0, false],
		[pos + ax * hx, ay, ax, hy * 2.0, false],
	]
	for wd: Array in walls:
		var c: Vector2 = wd[0]
		var along: Vector2 = wd[1]
		var nrm: Vector2 = wd[2]
		var length: float = wd[3]
		var front: bool = wd[4]
		var count := int((length - 1.5) / spacing)
		if count < 1:
			if kind == L.Kind.CHURCH and length >= 4.0:
				count = 1
			else:
				continue
		var n3 := Vector3(nrm.x, 0, nrm.y)
		var face := c + nrm * 0.06
		var door_slot := int(count / 2.0) if front and kind != L.Kind.CHURCH else -1
		for f in floors:
			for k in count:
				var off := (float(k) - (count - 1) * 0.5) * (length / count)
				var p := face + along * off
				if f == 0 and k == door_slot:
					var dw := 3.6 if kind in [L.Kind.BARN, L.Kind.WORKSHOP] else 1.2
					var dh := minf(3.8 if dw > 3.0 else 2.3, fh - 0.3)
					_panel(DOOR, p, along, n3, dw, floor_y, floor_y + dh)
					continue
				var y0 := floor_y + f * fh + sill
				_panel(WINDOW, p, along, n3, win.x, y0, y0 + win.y)


func _panel(m: Array, p: Vector2, along: Vector2, n: Vector3, width: float, y0: float, y1: float) -> void:
	var a := p - along * width * 0.5
	var b := p + along * width * 0.5
	details.quad(m, _v(a, y0), _v(b, y0), _v(b, y1), _v(a, y1), n)
