extends Node3D
## Draws a station (`assets/buildings/station_small.glb`: platform, building,
## canopy, lamps) at every station node, beside the track and along it.
##
## The model's track axis is its local z (x = 0) with the platform on +X;
## here that axis follows the track through the node (the bisector of the two
## straightest tracks, or the only track at a terminus). The platform is
## lengthened with copies of the model's `Platform` mesh so a whole train
## fits: centred on the node for a through station (trains stop with their
## front at the node from either side), running into the line at a terminus.
## Each platform piece stands on the rail top at its place and follows the
## track's grade; a stone plinth under it reaches down to the ground. The
## side is the one without other tracks in the way, else the one facing the
## nearest town.
##
## Each station is a node `Station_<node id>`; `sync()` rebuilds a station
## when its node or the tracks at it change.

const Ground := preload("res://world/ground.gd")
const RailPaths := preload("res://world/rail_paths.gd")
const TrackMesh := preload("res://world/track_mesh.gd")

const SCENE := "res://assets/buildings/station_small.glb"
const PLATFORM_MESH := "Platform"
const END_MARGIN := 4.0 ## Platform beyond the train at each end (m).
const PLINTH_DEPTH := 6.0 ## How far the plinth reaches below the rail top.
const PLINTH_COLOR := Color(0.55, 0.52, 0.48)

var sim: SimWorld
var paths: RailPaths
var train_length := 40.0

var _scene: PackedScene
var _platform_length := 18.1
var _platform_x := Vector2(1.7, 8.9) ## Near and far edge of the platform.
var _stations := {} ## node id -> {node: Node3D, key: String}
var _plinth_material: StandardMaterial3D


func setup(p_sim: SimWorld, p_paths: RailPaths, p_train_length: float) -> void:
	sim = p_sim
	paths = p_paths
	train_length = p_train_length
	if _scene == null and ResourceLoader.exists(SCENE):
		_scene = load(SCENE) as PackedScene
		if _scene != null:
			_measure()
	if _plinth_material == null:
		_plinth_material = StandardMaterial3D.new()
		_plinth_material.resource_name = "M_Station_Small_Plinth"
		_plinth_material.albedo_color = PLINTH_COLOR
		_plinth_material.roughness = 0.95
	sync()


## Finds the platform's size in the model.
func _measure() -> void:
	var probe := _scene.instantiate() as Node3D
	var platform := probe.find_child(PLATFORM_MESH, true, false) as MeshInstance3D
	if platform != null and platform.mesh != null:
		var aabb := platform.transform * platform.mesh.get_aabb()
		_platform_length = aabb.size.z
		_platform_x = Vector2(aabb.position.x, aabb.end.x)
	probe.free()


## Adds, moves and removes stations to match the sim.
func sync() -> void:
	if sim == null:
		return
	var seen := {}
	for n in sim.nodes():
		if not n["station"]:
			continue
		var id: int = n["id"]
		seen[id] = true
		var place := _placement(id, Vector2(n["x"], n["y"]))
		var key := var_to_str(place)
		var s: Dictionary = _stations.get(id, {})
		if not s.is_empty() and s["key"] == key:
			continue
		if not s.is_empty():
			(s["node"] as Node).queue_free()
		_stations[id] = {"node": _build(id, place), "key": key}
	for id: int in _stations.keys():
		if not seen.has(id):
			(_stations[id]["node"] as Node).queue_free()
			_stations.erase(id)


## The station node of sim node `id`, or null.
func station_node(id: int) -> Node3D:
	return _stations[id]["node"] if _stations.has(id) else null


## Where the station at node `id` goes: {at, axis (unit, sim plane, the
## model's +z), from, to (platform extent along the axis)}.
func _placement(id: int, at: Vector2) -> Dictionary:
	var dirs := paths.directions_at(id)
	var axis := Vector2.RIGHT
	var terminus := false
	var used := []
	if dirs.size() == 1:
		axis = dirs.values()[0]
		terminus = true
		used = dirs.keys()
	elif dirs.size() >= 2:
		# The two tracks closest to a straight line through the node.
		var best := INF
		for a: int in dirs:
			for b: int in dirs:
				if a < b:
					var dot: float = (dirs[a] as Vector2).dot(dirs[b])
					if dot < best:
						best = dot
						axis = ((dirs[a] as Vector2) - (dirs[b] as Vector2)).normalized()
						used = [a, b]
		if axis.length() < 0.5:
			axis = Vector2.RIGHT
	var from := -(train_length + END_MARGIN)
	var to := train_length + END_MARGIN
	if terminus:
		from = -END_MARGIN * 2.0
	# Platform on the model's +X: pick the side (flip the axis) with the
	# fewest other tracks crossing it, then the one facing the nearest town.
	var best_side := 1.0
	var best_score := INF
	for sign: float in [1.0, -1.0]:
		var ax := axis * sign
		var side := Vector2(ax.y, -ax.x) # model +X for model +Z = ax
		var lo := from if sign > 0.0 else -to
		var hi := to if sign > 0.0 else -from
		var score := 0.0
		for t: int in paths.tracks:
			if t in used:
				continue
			var tr: Dictionary = paths.tracks[t]
			if _crosses(at, ax, side, lo, hi, tr["pa"], tr["pb"]):
				score += 10.0
		score -= _town_bias(at, side) * 0.1
		if score < best_score:
			best_score = score
			best_side = sign
	axis *= best_side
	if best_side < 0.0:
		var f := from
		from = -to
		to = -f
	return {"at": at, "axis": axis, "from": snappedf(from, 0.01), "to": snappedf(to, 0.01)}


## `true` if segment pa-pb passes over the platform strip.
func _crosses(at: Vector2, ax: Vector2, side: Vector2, lo: float, hi: float,
		pa: Vector2, pb: Vector2) -> bool:
	for i in 21:
		var p := pa.lerp(pb, i / 20.0) - at
		var z := p.dot(ax)
		var x := p.dot(side)
		if z >= lo and z <= hi and x >= _platform_x.x - 1.5 and x <= _platform_x.y + 1.0:
			return true
	return false


## How much `side` faces the nearest town (-1..1).
func _town_bias(at: Vector2, side: Vector2) -> float:
	var nearest := Vector2.INF
	for p in sim.town_positions():
		if nearest == Vector2.INF or p.distance_to(at) < nearest.distance_to(at):
			nearest = p
	if nearest == Vector2.INF or nearest.distance_to(at) < 1.0:
		return 0.0
	return side.dot((nearest - at).normalized())


## Rail-top height beside the node at sim point `p` (the track's own
## height there, like track_mesh.gd).
func _rail_height(p: Vector2) -> float:
	var ground := Ground.height_at(sim, p.x, p.y)
	return maxf(ground, sim.terrain_water_level() + TrackMesh.WATER_CLEARANCE) + RailPaths.RAIL_TOP


func _build(id: int, place: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Station_%d" % id
	add_child(root)
	var at: Vector2 = place["at"]
	var axis: Vector2 = place["axis"]
	var from: float = place["from"]
	var to: float = place["to"]
	var pieces := maxi(ceili((to - from) / _platform_length), 1)
	var start := (from + to) * 0.5 - pieces * _platform_length * 0.5
	# The building stands on the piece at the node (the buffer stop end of
	# a terminus).
	var main := clampi(int(floor((0.0 - start) / _platform_length)), 0, pieces - 1)
	var model: Node3D = null
	var platform: MeshInstance3D = null
	if _scene != null:
		model = _scene.instantiate() as Node3D
		model.name = "Model"
		platform = model.find_child(PLATFORM_MESH, true, false) as MeshInstance3D
	var plinth := BoxMesh.new()
	plinth.size = Vector3(_platform_x.y - _platform_x.x - 0.1, PLINTH_DEPTH, _platform_length)
	plinth.material = _plinth_material
	for i in pieces:
		var z0 := start + i * _platform_length
		var z1 := z0 + _platform_length
		var p0 := at + axis * z0
		var p1 := at + axis * z1
		var h0 := _rail_height(p0)
		var h1 := _rail_height(p1)
		var mid := (p0 + p1) * 0.5
		var fwd := Vector3(p1.x - p0.x, h1 - h0, p1.y - p0.y).normalized()
		# Model +Z along the axis: looking_at points -Z, so look backwards.
		var piece := Node3D.new()
		piece.name = "Piece%d" % i
		piece.transform = Transform3D(Basis.looking_at(-fwd, Vector3.UP),
				Vector3(mid.x, (h0 + h1) * 0.5, mid.y))
		root.add_child(piece)
		var base := MeshInstance3D.new()
		base.name = "Plinth"
		base.mesh = plinth
		base.position = Vector3((_platform_x.x + _platform_x.y) * 0.5, -PLINTH_DEPTH * 0.5 + 0.02, 0.0)
		piece.add_child(base)
		if model != null and i == main:
			piece.add_child(model)
		elif platform != null:
			var copy := MeshInstance3D.new()
			copy.name = PLATFORM_MESH
			copy.mesh = platform.mesh
			copy.transform = platform.transform
			piece.add_child(copy)
	return root
