extends Node3D
## Chunked heightfield terrain around the camera, plus the water surface.
##
## Heights come from the simulation (`SimWorld.terrain_heights`), so the
## ground matches picking and placement exactly at the grid points. The
## world is cut into square chunks; each chunk is a grid mesh whose spacing
## grows with its distance to the camera (a few levels of detail), with a
## skirt hanging down its edges to hide cracks between levels. Chunks are
## (re)built a few per frame, nearest first, within a time budget. Far from
## the camera, bigger far chunks cover the ground with fewer meshes.
##
## Every vertex carries data for the terrain shader; see world/README.md.

const GROUND_SHADER := preload("res://art/shaders/painterly_ground.gdshader")

const CHUNK_SIZE := 1024.0 ## Metres per near chunk side.
const FAR_CHUNKS := 4 ## A far chunk covers FAR_CHUNKS x FAR_CHUNKS near chunks.
## Grid spacing in metres per level of detail (0 = nearest). Levels 0 to 2
## are near chunks, 3 and 4 far chunks.
const LOD_STEPS: Array[float] = [16.0, 32.0, 64.0, 128.0, 256.0]
## Camera distance up to which near levels 0 and 1 are used (level 2 beyond).
const LOD_DISTANCES: Array[float] = [2200.0, 4500.0]
## Far chunks are used from this distance, the coarsest level beyond FAR_COARSE.
const FAR_SPLIT := 8000.0
const FAR_COARSE := 16000.0
const HEIGHT_NORM := 250.0 ## Height mapped to 1.0 in COLOR.r.
const UV_SCALE := 100.0 ## Metres per UV unit (UV = world xz / UV_SCALE).
const MIN_RADIUS := 12000.0
const MAX_RADIUS := 28000.0

## Milliseconds per frame spent building chunks.
@export var budget_ms := 5.0

var sim: SimWorld
var camera: Camera3D
var material: ShaderMaterial
var water: MeshInstance3D

var _chunks := {} ## Vector3i (x, z, size level) -> {"lod": int, "node": MeshInstance3D}
var _water_level := 0.0


func setup(p_sim: SimWorld, p_camera: Camera3D) -> void:
	sim = p_sim
	camera = p_camera
	_water_level = sim.terrain_water_level()
	material = ShaderMaterial.new()
	material.shader = GROUND_SHADER
	_make_water()
	update_chunks(1000.0)


func _process(_delta: float) -> void:
	if sim != null and camera != null:
		update_chunks(budget_ms)


## Builds everything the current view needs right now (tests, screenshots).
func build_all_now() -> void:
	update_chunks(1.0e9)


## Number of chunks currently shown.
func chunk_count() -> int:
	return _chunks.size()


## Adds, rebuilds and drops chunks for the current camera, spending at most
## `budget` milliseconds on building. Far away, one far chunk replaces
## FAR_CHUNKS x FAR_CHUNKS near chunks; the two never overlap.
func update_chunks(budget: float) -> void:
	var cam := camera.global_position
	var ground := sim.terrain_height(cam.x, cam.z)
	var above := maxf(cam.y - ground, 0.0)
	var radius := clampf(9000.0 + above * 3.0, MIN_RADIUS, MAX_RADIUS)
	_place_water(cam, radius)

	var far_size := CHUNK_SIZE * FAR_CHUNKS
	var s0 := Vector2i(floori((cam.x - radius) / far_size), floori((cam.z - radius) / far_size))
	var s1 := Vector2i(floori((cam.x + radius) / far_size), floori((cam.z + radius) / far_size))
	var wanted := {}
	var todo: Array = [] # [distance, key, lod]
	for sz in range(s0.y, s1.y + 1):
		for sx in range(s0.x, s1.x + 1):
			var d := _distance(cam, ground, Vector2(sx, sz) * far_size, far_size)
			if d > radius:
				continue
			if d >= FAR_SPLIT:
				_want(Vector3i(sx, sz, 1), 4 if d >= FAR_COARSE else 3, d, wanted, todo)
				continue
			for cz in range(sz * FAR_CHUNKS, (sz + 1) * FAR_CHUNKS):
				for cx in range(sx * FAR_CHUNKS, (sx + 1) * FAR_CHUNKS):
					var dc := _distance(cam, ground, Vector2(cx, cz) * CHUNK_SIZE, CHUNK_SIZE)
					_want(Vector3i(cx, cz, 0), _lod_for(dc), dc, wanted, todo)
	for key: Vector3i in _chunks.keys():
		if not wanted.has(key):
			(_chunks[key]["node"] as Node).queue_free()
			_chunks.erase(key)
	todo.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var start := Time.get_ticks_usec()
	for item: Array in todo:
		if float(Time.get_ticks_usec() - start) / 1000.0 > budget:
			break
		_build_chunk(item[1], item[2])


func _want(key: Vector3i, lod: int, d: float, wanted: Dictionary, todo: Array) -> void:
	wanted[key] = true
	var have: Dictionary = _chunks.get(key, {})
	if have.is_empty() or int(have["lod"]) != lod:
		todo.append([d, key, lod])


## Distance from the camera to the nearest point of the square at `corner`
## with side `size`, taken at the height of the ground under the camera.
static func _distance(cam: Vector3, ground: float, corner: Vector2, size: float) -> float:
	var dx := maxf(maxf(corner.x - cam.x, cam.x - (corner.x + size)), 0.0)
	var dz := maxf(maxf(corner.y - cam.z, cam.z - (corner.y + size)), 0.0)
	return Vector3(dx, cam.y - ground, dz).length()


func _lod_for(distance: float) -> int:
	for i in LOD_DISTANCES.size():
		if distance < LOD_DISTANCES[i]:
			return i
	return LOD_DISTANCES.size()


## Chunk `key` is (x, z, size level): level 0 is a near chunk of
## CHUNK_SIZE, level 1 a far chunk of CHUNK_SIZE * FAR_CHUNKS.
func _build_chunk(key: Vector3i, lod: int) -> void:
	var size := CHUNK_SIZE * (FAR_CHUNKS if key.z == 1 else 1)
	var node := MeshInstance3D.new()
	node.name = "Chunk_%d_%d_%d" % [key.x, key.y, key.z]
	node.position = Vector3(key.x * size, 0.0, key.y * size)
	node.mesh = build_chunk_mesh(Vector2(key.x, key.y) * size, size, LOD_STEPS[lod])
	node.material_override = material
	# Only the nearest levels are worth shadow maps.
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if lod <= 1 \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	var old: Dictionary = _chunks.get(key, {})
	if not old.is_empty():
		(old["node"] as Node).queue_free()
	_chunks[key] = {"lod": lod, "node": node}


## The mesh of the square with its corner at world `corner` (x, z) and side
## `size`, with `step` metres between grid points, in coordinates relative
## to the corner.
func build_chunk_mesh(corner: Vector2, size: float, step: float) -> ArrayMesh:
	var n := int(size / step) + 1 # vertices per side
	var x0 := corner.x
	var z0 := corner.y
	# One extra ring of heights for normals that match the neighbours.
	var m := n + 2
	var h := sim.terrain_heights(x0 - step, z0 - step, step, m, m)
	var wet := sim.terrain_wetness(x0, z0, step, n, n)

	var count := n * n + 4 * n # grid plus skirt
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var custom := PackedFloat32Array()
	verts.resize(count)
	normals.resize(count)
	colors.resize(count)
	uvs.resize(count)
	custom.resize(count * 4)

	var i := 0
	for iz in n:
		for ix in n:
			var c := (iz + 1) * m + ix + 1
			var y := h[c]
			var dx := h[c + 1] - h[c - 1]
			var dz := h[c + m] - h[c - m]
			var nrm := Vector3(-dx, 2.0 * step, -dz).normalized()
			var slope := sqrt(dx * dx + dz * dz) / (2.0 * step) # rise over run
			var w := wet[iz * n + ix]
			verts[i] = Vector3(ix * step, y, iz * step)
			normals[i] = nrm
			colors[i] = Color(clampf(y / HEIGHT_NORM, 0.0, 1.0), clampf(slope, 0.0, 1.0), w, 1.0)
			uvs[i] = Vector2(x0 + ix * step, z0 + iz * step) / UV_SCALE
			custom[i * 4] = y
			custom[i * 4 + 1] = slope
			custom[i * 4 + 2] = w
			custom[i * 4 + 3] = maxf(_water_level - y, 0.0)
			i += 1

	var indices := PackedInt32Array()
	indices.resize((n - 1) * (n - 1) * 6 + 4 * (n - 1) * 6)
	var k := 0
	for iz in n - 1:
		for ix in n - 1:
			var a := iz * n + ix
			var b := a + 1
			var c := a + n
			var d := c + 1
			indices[k] = a
			indices[k + 1] = b
			indices[k + 2] = c
			indices[k + 3] = b
			indices[k + 4] = d
			indices[k + 5] = c
			k += 6

	# Skirts: a copy of each edge row pushed down, stitched to the edge.
	var skirt := step * 0.75 + 8.0
	var edges: Array[PackedInt32Array] = [
		_edge(n, 0, 1), # north, west to east
		_edge(n, n - 1, n), # east, north to south
		_edge(n, n * n - 1, -1), # south, east to west
		_edge(n, n * (n - 1), -n), # west, south to north
	]
	for edge in edges:
		var base := i
		for j in n:
			var src := edge[j]
			verts[i] = verts[src] - Vector3(0.0, skirt, 0.0)
			normals[i] = normals[src]
			colors[i] = colors[src]
			uvs[i] = uvs[src]
			for q in 4:
				custom[i * 4 + q] = custom[src * 4 + q]
			i += 1
		for j in n - 1:
			var t0 := edge[j]
			var t1 := edge[j + 1]
			var b0 := base + j
			var b1 := base + j + 1
			# Edges run clockwise seen from above, so the skirt faces out.
			indices[k] = t0
			indices[k + 1] = b1
			indices[k + 2] = t1
			indices[k + 3] = t0
			indices[k + 4] = b0
			indices[k + 5] = b1
			k += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	var fmt := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, fmt)
	return mesh


## Indices of one chunk edge: `n` vertices from `first`, `stride` apart.
static func _edge(n: int, first: int, stride: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(n)
	for j in n:
		out[j] = first + j * stride
	return out


func _make_water() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(2.0, 2.0) # scaled to the view radius
	var mat := StandardMaterial3D.new()
	# The art team can hand-tune it as res://art/materials/M_Water.tres.
	mat.resource_name = "M_Water"
	mat.albedo_color = Color(0.29, 0.47, 0.56)
	mat.roughness = 0.3
	water = MeshInstance3D.new()
	water.name = "Water"
	water.mesh = plane
	water.material_override = mat
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water)


func _place_water(cam: Vector3, radius: float) -> void:
	var snap := 256.0
	water.position = Vector3(snappedf(cam.x, snap), _water_level, snappedf(cam.z, snap))
	water.scale = Vector3(radius, 1.0, radius)
