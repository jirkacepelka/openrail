extends Node3D
## Woods, scattered trees and the farmland around towns.
##
## Builds a low-resolution mask of the map (R = forest density, G = farmland)
## from the world seed and the towns, plants trees where the mask says forest
## (MultiMesh per chunk, hidden beyond `visibility_end`) and hands the mask to
## the ground shader so its fields and dark forest floor line up with the
## trees. Trees under newly built track are cut down.
##
## ArtStyle creates this node; it only does something when the Session autoload
## holds a world. Uses the Blender trees in res://assets/nature/ when they are
## there, otherwise simple stand-in trees built here.

signal mask_ready(texture: Texture2D, rect: Vector4)

const TREE_SCENES := {
	"deciduous": "res://assets/nature/tree_deciduous.glb",
	"conifer": "res://assets/nature/tree_conifer.glb",
}
const GROUND_SCRIPT := "res://world/ground.gd"
const TOWNS_LAYOUT_SCRIPT := "res://world/towns_layout.gd"
const BROADLEAF_GREENS := [Color(0.34, 0.52, 0.24), Color(0.46, 0.54, 0.22), Color(0.28, 0.46, 0.30)]
const CONIFER_GREENS := [Color(0.20, 0.36, 0.27), Color(0.24, 0.40, 0.26), Color(0.18, 0.32, 0.28)]

## Metres covered by the mask and the trees, centred on the origin.
@export var extent := 15000.0
## Mask resolution in pixels per side.
@export var mask_size := 256
@export var chunk_size := 1000.0
## Trees in one mask pixel of full forest.
@export var trees_per_forest_pixel := 24
## Lone trees per mask pixel of open meadow (fractions are a chance).
@export var meadow_tree_chance := 1.2
## Beyond this distance from the camera trees are drawn as simple blobs.
@export var lod_distance := 2200.0
## Tree chunks further than this are hidden (the forest floor painted on the
## ground carries the woods further out).
@export var visibility_end := 12000.0
@export var town_clear_radius := 300.0
@export var farmland_radius := 1200.0
@export var track_clearance := 14.0
## Used when the trees can't sit on real terrain.
@export var ground_height := 0.0

var mask_texture: ImageTexture
var mask_rect: Vector4

var _sim: Object
var _ground_script: Script
var _water_level := -INF
var _heights := PackedFloat32Array() # mask_size², at mask pixel centres
var _meshes := {} # kind -> Mesh
var _chunks := {} # Vector2i -> {kind -> {"xforms": Array[Transform3D], "node": MultiMeshInstance3D}}
var _cleared_segments := 0
var _track_poll := 0.0
var _material_converter: Callable
var _canopy_materials := {}


## Plants trees for the world in `sim`. `material_converter` turns imported
## model materials into painterly ones (ArtStyle passes its own).
func build(sim: Object, seed_value: int, material_converter: Callable) -> void:
	_sim = sim
	_material_converter = material_converter
	if ResourceLoader.exists(GROUND_SCRIPT):
		var script := load(GROUND_SCRIPT) as Script
		for m in script.get_script_method_list():
			if m["name"] == "height_at":
				_ground_script = script
		for m in script.get_script_method_list():
			if m["name"] == "water_level" and _ground_script != null:
				_water_level = _ground_script.call("water_level", _sim)
	var started := Time.get_ticks_msec()
	var towns := _towns()
	print_verbose("Vegetation: towns %d ms" % (Time.get_ticks_msec() - started))
	var mask := _build_mask(seed_value, towns)
	print_verbose("Vegetation: mask %d ms" % (Time.get_ticks_msec() - started))
	mask_texture = ImageTexture.create_from_image(mask)
	mask_rect = Vector4(-extent * 0.5, -extent * 0.5, extent, extent)
	mask_ready.emit(mask_texture, mask_rect)
	_meshes["deciduous"] = _tree_mesh("deciduous")
	_meshes["conifer"] = _tree_mesh("conifer")
	_meshes["deciduous_far"] = _far_mesh(false)
	_meshes["conifer_far"] = _far_mesh(true)
	_scatter(mask, seed_value)
	print_verbose("Vegetation: scatter %d ms" % (Time.get_ticks_msec() - started))
	_hedgerows(towns, seed_value)
	print_verbose("Vegetation: hedges %d ms" % (Time.get_ticks_msec() - started))
	_clear_tracks()
	for key in _chunks:
		_rebuild_chunk(key)
	var trees := 0
	for chunk in _chunks.values():
		for entry in chunk.values():
			trees += entry["xforms"].size()
	print_verbose("Vegetation: %d trees in %d chunks, %d ms" % [trees, _chunks.size(), Time.get_ticks_msec() - started])


func _process(delta: float) -> void:
	if _sim == null:
		return
	_track_poll -= delta
	if _track_poll > 0.0:
		return
	_track_poll = 0.5
	_clear_tracks()


## Each town as [centre, area to keep clear, layout or {}]. With the town
## layouts (world/towns_layout.gd) the clear area is the town and its own
## fields; otherwise an estimate from the population.
func _towns() -> Array:
	var out := []
	if not _sim.has_method("town_positions"):
		return out
	var layout_script: Script = load(TOWNS_LAYOUT_SCRIPT) if ResourceLoader.exists(TOWNS_LAYOUT_SCRIPT) else null
	var pos: PackedVector2Array = _sim.town_positions()
	var names: PackedStringArray = _sim.town_names()
	var pops: PackedInt64Array = _sim.town_populations()
	for i in pos.size():
		var pop := pops[i] if i < pops.size() else 1000
		if layout_script != null and i < names.size():
			var layout: Dictionary = layout_script.call("generate", pos[i], names[i], int(pop))
			out.append([pos[i], float(layout["field_radius"]) + 60.0, layout])
		else:
			out.append([pos[i], town_clear_radius + sqrt(float(pop)) * 5.0 + farmland_radius, {}])
	return out


## R = forest density, G = farmland outside the towns, B = keep clear (towns
## and their fields).
func _build_mask(seed_value: int, towns: Array) -> Image:
	var forest_noise := FastNoiseLite.new()
	forest_noise.seed = seed_value
	forest_noise.frequency = 1.0 / 2200.0
	forest_noise.fractal_octaves = 4
	var farm_noise := FastNoiseLite.new()
	farm_noise.seed = seed_value + 7
	farm_noise.frequency = 1.0 / 3000.0
	farm_noise.fractal_octaves = 3
	var img := Image.create(mask_size, mask_size, false, Image.FORMAT_RGB8)
	var px := extent / mask_size
	_heights.resize(mask_size * mask_size)
	for y in mask_size:
		for x in mask_size:
			var wx := -extent * 0.5 + (x + 0.5) * px
			var wz := -extent * 0.5 + (y + 0.5) * px
			# Woods are commoner up in the hills, where nobody farms.
			var h := _height(wx, wz)
			_heights[y * mask_size + x] = h
			var hill := clampf((h - _water_level) / 160.0, 0.0, 1.0) if _water_level > -INF else 0.0
			var forest := smoothstep(0.1, 0.28, forest_noise.get_noise_2d(wx, wz) + hill * 0.22)
			var farm := smoothstep(0.25, 0.4, farm_noise.get_noise_2d(wx, wz)) * 0.8
			var keep_clear := 0.0
			for t in towns:
				var d: float = (t[0] as Vector2).distance_to(Vector2(wx, wz))
				var r: float = t[1]
				# The town draws its own fields; ours start further out.
				forest *= smoothstep(r, r + 450.0, d)
				farm *= smoothstep(r, r + 300.0, d)
				keep_clear = maxf(keep_clear, 1.0 - smoothstep(r - px, r, d))
			forest *= 1.0 - smoothstep(0.3, 0.6, farm)
			img.set_pixel(x, y, Color(forest, farm, keep_clear))
	return img


## Trees along some edges of the towns' fields, clear of the roads.
func _hedgerows(towns: Array, seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 17 + 3
	for t in towns:
		var layout: Dictionary = t[2]
		if layout.is_empty():
			continue
		var roads: Array = []
		for street in layout["streets"]:
			var pts: PackedVector2Array = street["points"]
			for k in pts.size() - 1:
				roads.append([pts[k], pts[k + 1], float(street["half_width"]) + 5.0])
		var built := float(layout["radius"]) + 20.0
		var centre: Vector2 = layout["center"]
		for field in layout["fields"]:
			var c := _rect_corners(field)
			for e in 4:
				if rng.randf() > 0.45:
					continue # most field edges have no hedge
				var a: Vector2 = c[e]
				var b: Vector2 = c[(e + 1) % 4]
				var steps := int(a.distance_to(b) / 11.0)
				for k in steps:
					if rng.randf() > 0.7:
						continue
					var p := a.lerp(b, (k + rng.randf_range(0.3, 0.7)) / steps)
					if p.distance_to(centre) < built or _near_road(p, roads):
						continue
					_plant("deciduous", p, rng)


func _rect_corners(r: Dictionary) -> Array[Vector2]:
	var pos: Vector2 = r["pos"]
	var h: Vector2 = r["size"] * 0.5
	var ax := Vector2.from_angle(r["angle"])
	var ay := Vector2(-ax.y, ax.x)
	return [pos - ax * h.x - ay * h.y, pos + ax * h.x - ay * h.y, pos + ax * h.x + ay * h.y, pos - ax * h.x + ay * h.y]


func _near_road(p: Vector2, roads: Array) -> bool:
	for r in roads:
		if Geometry2D.get_closest_point_to_segment(p, r[0], r[1]).distance_to(p) < r[2]:
			return true
	return false


func _plant(kind: String, p: Vector2, rng: RandomNumberGenerator) -> void:
	var h := _grid_height(p.x, p.y)
	if h < _water_level + 1.0:
		return # rivers and lakes
	var s := rng.randf_range(1.0, 1.6)
	var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.9, 1.15), s))
	# Sunk a little: the grid height can be off by a bit on slopes.
	var xf := Transform3D(basis, Vector3(p.x, h - 1.0, p.y))
	var key := Vector2i(floori(p.x / chunk_size), floori(p.y / chunk_size))
	var chunk: Dictionary = _chunks.get_or_add(key, {})
	var entry: Dictionary = chunk.get_or_add(kind, {"xforms": []})
	entry["xforms"].append(xf)


func _scatter(mask: Image, seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 31 + 5
	var px := extent / mask_size
	for y in mask_size:
		for x in mask_size:
			var c := mask.get_pixel(x, y)
			var count := 0
			if c.b > 0.5:
				continue # a town or its fields
			if c.r > 0.05:
				count = int(round(c.r * trees_per_forest_pixel))
			elif c.g < 0.3:
				# Lone trees and small copses in the meadows.
				count = int(meadow_tree_chance) + (1 if rng.randf() < fmod(meadow_tree_chance, 1.0) else 0)
			if count == 0:
				continue
			# Mostly conifers in dense woods, broadleaf at the edges and in meadows.
			var conifer_share := smoothstep(0.4, 0.9, c.r) * 0.7
			for i in count:
				var wx := -extent * 0.5 + (x + rng.randf()) * px
				var wz := -extent * 0.5 + (y + rng.randf()) * px
				_plant("conifer" if rng.randf() < conifer_share else "deciduous", Vector2(wx, wz), rng)


## Ground height from the grid sampled with the mask, bilinear. Much
## cheaper than asking the terrain for every one of the trees.
func _grid_height(x: float, z: float) -> float:
	if _heights.is_empty():
		return _height(x, z)
	var px := extent / mask_size
	var gx := clampf((x + extent * 0.5) / px - 0.5, 0.0, mask_size - 1.001)
	var gz := clampf((z + extent * 0.5) / px - 0.5, 0.0, mask_size - 1.001)
	var ix := int(gx)
	var iz := int(gz)
	var fx := gx - ix
	var fz := gz - iz
	var i := iz * mask_size + ix
	var top := lerpf(_heights[i], _heights[i + 1], fx)
	var bottom := lerpf(_heights[i + mask_size], _heights[i + mask_size + 1], fx)
	return lerpf(top, bottom, fz)


func _height(x: float, z: float) -> float:
	if _ground_script != null:
		return _ground_script.call("height_at", _sim, x, z)
	return ground_height


func _rebuild_chunk(key: Vector2i) -> void:
	var chunk: Dictionary = _chunks[key]
	for kind in chunk:
		var entry: Dictionary = chunk[kind]
		var xforms: Array = entry["xforms"]
		# Visibility range is measured from the node origin: put it mid-chunk.
		var origin := Vector3((key.x + 0.5) * chunk_size, 0.0, (key.y + 0.5) * chunk_size)
		var buffer := PackedFloat32Array()
		buffer.resize(xforms.size() * 12)
		for i in xforms.size():
			var t: Transform3D = xforms[i].translated(-origin)
			var b := t.basis
			var o := i * 12
			buffer[o] = b.x.x; buffer[o + 1] = b.y.x; buffer[o + 2] = b.z.x; buffer[o + 3] = t.origin.x
			buffer[o + 4] = b.x.y; buffer[o + 5] = b.y.y; buffer[o + 6] = b.z.y; buffer[o + 7] = t.origin.y
			buffer[o + 8] = b.x.z; buffer[o + 9] = b.y.z; buffer[o + 10] = b.z.z; buffer[o + 11] = t.origin.z
		# Full trees up close, cheap blobs further out.
		for lod in ["near", "far"]:
			var node: MultiMeshInstance3D = entry.get(lod)
			if node == null:
				node = MultiMeshInstance3D.new()
				node.name = "Trees_%d_%d_%s_%s" % [key.x, key.y, kind, lod]
				node.position = origin
				node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
				if lod == "near":
					node.visibility_range_end = lod_distance
					node.visibility_range_end_margin = 300.0
				else:
					node.visibility_range_begin = lod_distance
					node.visibility_range_begin_margin = 300.0
					node.visibility_range_end = visibility_end
					node.visibility_range_end_margin = 600.0
					node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				add_child(node)
				entry[lod] = node
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = _meshes[kind] if lod == "near" else _meshes[kind + "_far"]
			mm.instance_count = xforms.size()
			if not xforms.is_empty():
				mm.buffer = buffer
			node.multimesh = mm


## Cuts down trees standing on track built since the last check.
func _clear_tracks() -> void:
	if not _sim.has_method("track_segments"):
		return
	var segs: PackedVector2Array = _sim.track_segments()
	if segs.size() == _cleared_segments:
		return
	var from := _cleared_segments if segs.size() > _cleared_segments else 0
	_cleared_segments = segs.size()
	var touched := {}
	var i := from
	while i + 1 < segs.size():
		var a := segs[i]
		var b := segs[i + 1]
		i += 2
		var lo := Vector2i(floori((minf(a.x, b.x) - track_clearance) / chunk_size), floori((minf(a.y, b.y) - track_clearance) / chunk_size))
		var hi := Vector2i(floori((maxf(a.x, b.x) + track_clearance) / chunk_size), floori((maxf(a.y, b.y) + track_clearance) / chunk_size))
		for cz in range(lo.y, hi.y + 1):
			for cx in range(lo.x, hi.x + 1):
				var key := Vector2i(cx, cz)
				if _chunks.has(key) and _cut(_chunks[key], a, b):
					touched[key] = true
	for key in touched:
		if _chunks[key].values()[0].has("near"):
			_rebuild_chunk(key)


func _cut(chunk: Dictionary, a: Vector2, b: Vector2) -> bool:
	var cut := false
	for kind in chunk:
		var entry: Dictionary = chunk[kind]
		var xforms: Array = entry["xforms"]
		var j := xforms.size() - 1
		while j >= 0:
			var o: Vector3 = xforms[j].origin
			var p := Geometry2D.get_closest_point_to_segment(Vector2(o.x, o.z), a, b)
			if p.distance_to(Vector2(o.x, o.z)) < track_clearance:
				xforms.remove_at(j)
				cut = true
			j -= 1
	return cut


func _tree_mesh(kind: String) -> Mesh:
	var path: String = TREE_SCENES[kind]
	if ResourceLoader.exists(path):
		var mesh := _mesh_from_scene(load(path))
		if mesh != null:
			return mesh
	return _conifer_mesh() if kind == "conifer" else _deciduous_mesh()


## First mesh of an imported model, painted, scaled to a 12 m tree.
func _mesh_from_scene(scene: PackedScene) -> Mesh:
	if scene == null:
		return null
	var root := scene.instantiate()
	var found := root.find_children("*", "MeshInstance3D", true, false)
	var result: ArrayMesh = null
	if not found.is_empty():
		var mi := found[0] as MeshInstance3D
		var source := mi.mesh
		var height := maxf(source.get_aabb().size.y, 0.01)
		var scale := 12.0 / height
		var st_mesh := ArrayMesh.new()
		for s in source.get_surface_count():
			var st := SurfaceTool.new()
			st.append_from(source, s, Transform3D(Basis().scaled(Vector3.ONE * scale), Vector3.ZERO))
			st.commit(st_mesh)
			var mat := source.surface_get_material(s)
			if _material_converter.is_valid():
				var painted: Material = _material_converter.call(mat)
				if painted != null:
					mat = painted
			st_mesh.surface_set_material(s, mat)
		result = st_mesh
	root.free()
	return result


func _deciduous_mesh() -> Mesh:
	var mesh := ArrayMesh.new()
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.35
	trunk.bottom_radius = 0.55
	trunk.height = 5.0
	trunk.radial_segments = 6
	trunk.rings = 1
	_add_surface(mesh, [[trunk, Transform3D(Basis(), Vector3(0, 2.5, 0))]], _trunk_material())
	var blob := SphereMesh.new()
	blob.radius = 3.4
	blob.height = 5.6
	blob.radial_segments = 9
	blob.rings = 5
	_add_surface(mesh, [
		[blob, Transform3D(Basis(), Vector3(0, 7.6, 0))],
		[blob, Transform3D(Basis().scaled(Vector3.ONE * 0.75), Vector3(1.8, 6.4, 0.8))],
		[blob, Transform3D(Basis().scaled(Vector3.ONE * 0.7), Vector3(-1.5, 6.8, -1.0))],
	], _canopy_material(BROADLEAF_GREENS))
	return mesh


func _conifer_mesh() -> Mesh:
	var mesh := ArrayMesh.new()
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.25
	trunk.bottom_radius = 0.45
	trunk.height = 3.0
	trunk.radial_segments = 6
	trunk.rings = 1
	_add_surface(mesh, [[trunk, Transform3D(Basis(), Vector3(0, 1.5, 0))]], _trunk_material())
	var tiers := []
	var sizes := [[3.2, 5.5, 4.8], [2.5, 4.6, 8.0], [1.7, 3.8, 10.9]] # radius, height, centre
	for s in sizes:
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = s[0]
		cone.height = s[1]
		cone.radial_segments = 8
		cone.rings = 1
		tiers.append([cone, Transform3D(Basis(), Vector3(0, s[2], 0))])
	_add_surface(mesh, tiers, _canopy_material(CONIFER_GREENS))
	return mesh


## A few triangles per tree, for the distance.
func _far_mesh(conifer: bool) -> Mesh:
	var mesh := ArrayMesh.new()
	if conifer:
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 3.0
		cone.height = 11.0
		cone.radial_segments = 4
		cone.rings = 0
		_add_surface(mesh, [[cone, Transform3D(Basis(), Vector3(0, 7.0, 0))]], _canopy_material(CONIFER_GREENS))
	else:
		var blob := SphereMesh.new()
		blob.radius = 4.0
		blob.height = 6.5
		blob.radial_segments = 5
		blob.rings = 1
		_add_surface(mesh, [[blob, Transform3D(Basis(), Vector3(0, 7.0, 0))]], _canopy_material(BROADLEAF_GREENS))
	return mesh


func _add_surface(mesh: ArrayMesh, parts: Array, material: Material) -> void:
	var st := SurfaceTool.new()
	for part in parts:
		st.append_from(part[0], 0, part[1])
	st.commit(mesh)
	mesh.surface_set_material(mesh.get_surface_count() - 1, material)


func _canopy_material(greens: Array) -> Material:
	if _canopy_materials.has(greens):
		return _canopy_materials[greens]
	var mat := ArtStyle.paint(greens[0]).duplicate() as ShaderMaterial
	_canopy_materials[greens] = mat
	mat.set_shader_parameter("vary_per_instance", true)
	mat.set_shader_parameter("instance_color_a", greens[0])
	mat.set_shader_parameter("instance_color_b", greens[1])
	mat.set_shader_parameter("instance_color_c", greens[2])
	mat.set_shader_parameter("brush_scale", 0.25)
	mat.set_shader_parameter("value_jitter", 0.25)
	mat.set_shader_parameter("rim_strength", 0.25)
	mat.set_shader_parameter("highlight_strength", 0.0)
	return mat


func _trunk_material() -> Material:
	return ArtStyle.paint(Color(0.36, 0.28, 0.24))
