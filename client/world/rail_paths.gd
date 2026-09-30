extends RefCounted
## The track network as rail-top paths, for placing vehicles on the rails.
## Every sim track is a straight 2D segment from node `a` to node `b`; its rail
## top follows the ground exactly like `world/track_mesh.gd` draws it
## (sampled every `TrackMesh.SAMPLE_STEP` metres, linear in between, just
## above the water on crossings). A position on the network is a track id, a
## distance `d` from its node `a` and a heading (`fwd`: towards `b`).
##
##   var paths := RailPaths.new()
##   paths.sync(sim) # after network changes; cheap when nothing changed
##   var p := paths.point(track, d) # rail top, Godot coordinates

const TrackMesh := preload("res://world/track_mesh.gd")

## Height of the rail top above the track base (ground or water crossing).
const RAIL_TOP := TrackMesh.BED_TOP + TrackMesh.SLEEPER_SIZE.y + TrackMesh.RAIL_HEIGHT

## track id -> {a, b, pa: Vector2, pb: Vector2, length, heights: PackedFloat32Array}
var tracks := {}
## node id -> Array of track ids touching it.
var at_node := {}
## node id -> Vector2 sim position.
var nodes := {}

var _key := PackedVector2Array()


## Rebuilds the paths when the network changed. Returns `true` if it did.
func sync(sim: SimWorld) -> bool:
	var segments := sim.track_segments()
	var node_list := sim.nodes()
	if segments == _key and node_list.size() == nodes.size() and not tracks.is_empty():
		return false
	_key = segments
	tracks.clear()
	at_node.clear()
	nodes.clear()
	for n in node_list:
		nodes[n["id"]] = Vector2(n["x"], n["y"])
	var water := sim.terrain_water_level() + TrackMesh.WATER_CLEARANCE
	var list := sim.tracks()
	# One terrain query for the samples of every track.
	var samples := PackedVector2Array()
	var counts := PackedInt32Array()
	for t in list:
		var pa: Vector2 = nodes[t["a"]]
		var pb: Vector2 = nodes[t["b"]]
		var n := maxi(ceili(pa.distance_to(pb) / TrackMesh.SAMPLE_STEP), 1)
		counts.append(n)
		for i in n + 1:
			samples.append(pa.lerp(pb, float(i) / float(n)))
	var ground := sim.terrain_heights_at(samples)
	var k := 0
	for j in list.size():
		var t: Dictionary = list[j]
		var id: int = t["id"]
		var pa: Vector2 = nodes[t["a"]]
		var pb: Vector2 = nodes[t["b"]]
		var heights := PackedFloat32Array()
		for i in counts[j] + 1:
			heights.append(maxf(ground[k], water) + RAIL_TOP)
			k += 1
		tracks[id] = {"a": t["a"], "b": t["b"], "pa": pa, "pb": pb,
				"length": pa.distance_to(pb), "heights": heights}
		for node: int in [t["a"], t["b"]]:
			if not at_node.has(node):
				at_node[node] = []
			(at_node[node] as Array).append(id)
	return true


## Rail-top point (Godot coordinates) on `track` at distance `d` from node a.
func point(track: int, d: float) -> Vector3:
	var t: Dictionary = tracks[track]
	var length: float = t["length"]
	var heights: PackedFloat32Array = t["heights"]
	var n := heights.size() - 1
	var f := clampf(d / maxf(length, 0.001), 0.0, 1.0)
	var p: Vector2 = (t["pa"] as Vector2).lerp(t["pb"], f)
	var fi := f * n
	var i0 := mini(int(fi), n - 1)
	var h := lerpf(heights[i0], heights[i0 + 1], fi - i0)
	return Vector3(p.x, h, p.y)


## Distance from node a of the point on `track` closest to sim point `p`.
func distance_on(track: int, p: Vector2) -> float:
	var t: Dictionary = tracks[track]
	var pa: Vector2 = t["pa"]
	var dir: Vector2 = ((t["pb"] as Vector2) - pa).normalized()
	return clampf((p - pa).dot(dir), 0.0, t["length"])


## Moves `dist` metres from (track, d, fwd) along the rails. At a node it
## takes the most recent track of `prefer` found there (for example the
## tracks a train came along), else the straightest continuation. Returns
## [track, d, fwd, left] where `left` is what could not be travelled
## because the rails end.
func advance(track: int, d: float, fwd: bool, dist: float, prefer: Array = []) -> Array:
	var guard := 0
	while guard < 256:
		guard += 1
		var t: Dictionary = tracks[track]
		var length: float = t["length"]
		var room := length - d if fwd else d
		if dist <= room:
			return [track, d + dist if fwd else d - dist, fwd, 0.0]
		dist -= room
		var node: int = t["b"] if fwd else t["a"]
		var next := _next_track(track, node, fwd, prefer)
		if next < 0:
			return [track, length if fwd else 0.0, fwd, dist]
		track = next
		fwd = tracks[next]["a"] == node
		d = 0.0 if fwd else tracks[next]["length"]
	return [track, d, fwd, dist]


## The track to continue on after leaving `track` at `node`, or -1.
func _next_track(track: int, node: int, fwd: bool, prefer: Array) -> int:
	var here: Array = at_node.get(node, [])
	var best := -1
	var best_rank := -1
	for c: int in here:
		if c != track:
			var rank := prefer.rfind(c)
			if rank > best_rank:
				best_rank = rank
				best = c
	if best >= 0:
		return best
	var t: Dictionary = tracks[track]
	var u: Vector2 = ((t["pb"] as Vector2) - (t["pa"] as Vector2)).normalized()
	if not fwd:
		u = -u
	var best_dot := -INF
	var at: Vector2 = nodes[node]
	for c: int in here:
		if c == track or tracks[c]["length"] < 0.01:
			continue
		var o: Dictionary = tracks[c]
		var far: Vector2 = o["pb"] if o["a"] == node else o["pa"]
		var dot := u.dot((far - at).normalized())
		if dot > best_dot:
			best_dot = dot
			best = c
	return best


## Unit directions (sim plane) of the tracks leaving `node`, by track id.
func directions_at(node: int) -> Dictionary:
	var out := {}
	var at: Vector2 = nodes.get(node, Vector2.ZERO)
	for c: int in at_node.get(node, []):
		var o: Dictionary = tracks[c]
		var far: Vector2 = o["pb"] if o["a"] == node else o["pa"]
		if far.distance_to(at) > 0.01:
			out[c] = (far - at).normalized()
	return out
