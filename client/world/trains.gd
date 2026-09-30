extends Node3D
## Draws every sim train as a steam locomotive and covered wagons
## (`assets/vehicles/*.glb`) on the rails. The simulation moves a point per
## train (the front of the train); the cars trail behind it along the tracks
## it came from (`RailPaths.advance`), each one standing on its own two end
## wheelsets, so it turns and pitches with the rails under it.
##
## Rendering is instanced: one `MultiMeshInstance3D` per model part (body,
## side rods, every wheelset) for all trains together, refilled every frame
## for the cars within `draw_distance` of the camera. Wheels turn with the
## distance travelled. Materials are the models' own `M_<Asset>_<Mesh>` (and
## `M_lamp_glow`), taken after `ArtStyle` repainted them, so the painterly
## look applies.
##
## Every train also has a node `Train_<id>` with one plain `Node3D` child per
## car (`Loco`, `Wagon1`, ...) placed at the car's origin (on the rail top,
## centred, facing its -Z): handy for labels, cameras and tests.
##
## Motion between sim ticks is smoothed: the drawn train chases the sim point
## along the rails it just travelled. When a train turns round (at a terminus
## or a station behind it) its locomotive runs round to the other end, and
## for the first metres after that the drawn train eases out of the cars'
## old place, so no car stands past the end of the line.

const RailPaths := preload("res://world/rail_paths.gd")

const LOCO_SCENE := "res://assets/vehicles/locomotive_steam.glb"
const WAGON_SCENE := "res://assets/vehicles/wagon_covered.glb"
## Passengers per wagon: a train of `SimWorld.train_capacity()` gets this
## many wagons (at least MIN_WAGONS, at most MAX_WAGONS).
const PASSENGERS_PER_WAGON := 40
const MIN_WAGONS := 2
const MAX_WAGONS := 6
const COUPLING_GAP := 0.25 ## Between the buffers of neighbouring cars (m).
const CHASE_RATE := 8.0 ## How fast the drawn train catches up with the sim (1/s).
const MAX_LAG := 60.0 ## Beyond this lag the drawn train jumps to the sim.
const HISTORY := 12 ## Tracks remembered per train to trail the cars along.
const FAR_UPDATE := 0.25 ## Seconds between moves of trains too far to draw.


## One mesh of a vehicle model, drawn for all cars through one MultiMesh.
class Part:
	var name := ""
	var rest := Transform3D.IDENTITY ## In the model's space.
	var wheel_radius := 0.0 ## > 0 for wheelsets, which turn around local X.
	var crank := 0.0 ## > 0 for side rods, which circle with the wheels.
	var instances: MultiMeshInstance3D
	var used := 0


## A vehicle model: its parts and where its buffers and end axles are.
class Model:
	var parts: Array[Part] = []
	var front := -5.0 ## Local z of the front buffer (vehicles face -Z).
	var back := 5.0 ## Local z of the rear buffer.
	var axle_front := -3.0 ## Local z of the front axle.
	var axle_back := 3.0 ## Local z of the rear axle.
	var driver_radius := 0.75 ## Radius the side rods' crank follows.

	func length() -> float:
		return back - front


var sim: SimWorld
var paths := RailPaths.new()
var loco: Model
var wagon: Model
var wagons := 3
## Cars further than this from the camera are not drawn.
var draw_distance := 4500.0

## train id -> {node: Node3D, track, fwd, pos: Vector2, odo, shown, since,
## history: Array}
var _state := {}


func setup(p_sim: SimWorld) -> void:
	sim = p_sim
	if loco == null:
		loco = _load_model(LOCO_SCENE, "Loco", Color(0.16, 0.5, 0.48), 10.2)
		wagon = _load_model(WAGON_SCENE, "Wagon", Color(0.55, 0.22, 0.2), 8.3)
	var capacity := sim.train_capacity() if sim != null else 100
	wagons = clampi(ceili(float(capacity) / PASSENGERS_PER_WAGON), MIN_WAGONS, MAX_WAGONS)
	sync()


## Length of a whole train over its buffers in metres.
func train_length() -> float:
	return loco.length() + wagons * (wagon.length() + COUPLING_GAP)


## Picks up network changes and new or removed trains.
func sync() -> void:
	if sim == null:
		return
	paths.sync(sim)
	update(0.0)


func _process(delta: float) -> void:
	update(delta)


## Moves every train to the sim state and redraws. `delta` is the time since
## the last update (0 = snap to the sim).
func update(delta: float) -> void:
	if sim == null:
		return
	var list := sim.trains()
	for t in list:
		if not paths.tracks.has(t["track"]):
			paths.sync(sim) # the network changed since the last sync
			break
	_reserve(loco, list.size())
	_reserve(wagon, list.size() * wagons)
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var seen := {}
	for t in list:
		var id: int = t["id"]
		if not paths.tracks.has(t["track"]):
			continue
		seen[id] = true
		var s := _observe(id, t, delta)
		_place(s, cam, delta)
	for id: int in _state.keys():
		if not seen.has(id):
			(_state[id]["node"] as Node).queue_free()
			_state.erase(id)
	for part in loco.parts + wagon.parts:
		part.instances.multimesh.visible_instance_count = part.used


## Centre of train `id` on the rails (Godot coordinates), or null.
func train_position(id: int) -> Variant:
	if not _state.has(id):
		return null
	var cars := (_state[id]["node"] as Node3D).get_children()
	if cars.is_empty():
		return null
	var a := (cars[0] as Node3D).position
	var b := (cars[cars.size() - 1] as Node3D).position
	return (a + b) * 0.5


## The per-car nodes of train `id` (locomotive first), or [].
func cars_of(id: int) -> Array[Node3D]:
	var out: Array[Node3D] = []
	if _state.has(id):
		for c in (_state[id]["node"] as Node3D).get_children():
			out.append(c as Node3D)
	return out


## Follows one sim train: remembers the tracks it travelled, notices when it
## turns round and advances the drawn position towards the sim.
func _observe(id: int, t: Dictionary, delta: float) -> Dictionary:
	var track: int = t["track"]
	var fwd: bool = t.get("forward", true)
	var pos := Vector2(t["x"], t["y"])
	var s: Dictionary = _state.get(id, {})
	if s.is_empty():
		s = _new_train(id, track, fwd, pos)
		_state[id] = s
	var moved := pos.distance_to(s["pos"])
	if track == s["track"] and fwd != s["fwd"]:
		# Turned round: the cars stay where they are, the locomotive runs
		# round to the other end.
		# The tracks it came along are now ahead of it: keep them as hints.
		s["since"] = 0.0
		s["lag"] = 0.0
	elif track != s["track"]:
		var history: Array = s["history"]
		history.append(s["track"])
		if history.size() > HISTORY:
			history.pop_front()
	s["since"] = float(s["since"]) + moved
	s["lag"] = float(s["lag"]) + moved
	if delta <= 0.0 or float(s["lag"]) > MAX_LAG:
		s["lag"] = 0.0
	else:
		s["lag"] = float(s["lag"]) * exp(-CHASE_RATE * delta)
		if float(s["lag"]) < 0.005:
			s["lag"] = 0.0
	s["track"] = track
	s["fwd"] = fwd
	s["pos"] = pos
	return s


func _new_train(id: int, track: int, fwd: bool, pos: Vector2) -> Dictionary:
	var node := Node3D.new()
	node.name = "Train_%d" % id
	add_child(node)
	var car := Node3D.new()
	car.name = "Loco"
	node.add_child(car)
	for i in wagons:
		car = Node3D.new()
		car.name = "Wagon%d" % (i + 1)
		node.add_child(car)
	# A train placed next to the end of the line starts with its cars in
	# front of it, as if it had just turned round there.
	var since := INF
	var back := paths.advance(track, paths.distance_on(track, pos), not fwd,
			2.0 * train_length())
	if float(back[3]) > 0.0:
		since = 2.0 * train_length() - float(back[3])
	return {"node": node, "track": track, "fwd": fwd, "pos": pos, "odo": 0.0,
			"lag": 0.0, "since": since, "history": [], "head": Vector3.INF}


## Lays the cars of one train along the rails and adds them to the draw lists.
func _place(s: Dictionary, cam: Camera3D, delta: float) -> void:
	var track: int = s["track"]
	var fwd: bool = s["fwd"]
	var at2: Vector2 = s["pos"]
	var far := cam != null and Vector2(cam.global_position.x, cam.global_position.z).distance_to(at2) > draw_distance + 100.0
	# Standing trains keep their cars; far ones (not drawn) move a few
	# times a second, enough for their labels.
	var key := [track, fwd, at2, s["lag"], minf(s["since"], 1e9), (s["history"] as Array).size()]
	s["far_time"] = float(s.get("far_time", 0.0)) + delta
	if s.has("xfs") and (key == s["key"] or (far and float(s["far_time"]) < FAR_UPDATE)):
		if not far:
			var xfs: Array = s["xfs"]
			for i in xfs.size():
				_draw(loco if i == 0 else wagon, xfs[i], s["odo"])
		return
	s["key"] = key
	s["far_time"] = 0.0
	var d := paths.distance_on(track, s["pos"])
	# Tracks to prefer at junctions, most recent last.
	var history: Array = (s["history"] as Array) + [track]
	var length := train_length()
	var lag: float = s["lag"]
	# Visible distance since turning round; for the first 2 lengths the
	# drawn front runs ahead of the sim point, easing from the old tail.
	var x := maxf(float(s["since"]) - lag, 0.0)
	var ahead := 0.0
	if x < 2.0 * length:
		ahead = (x - 2.0 * length) * (x - 2.0 * length) / (4.0 * length)
	var head: Array
	if ahead >= lag:
		head = paths.advance(track, d, fwd, ahead - lag, history)
	else:
		head = paths.advance(track, d, not fwd, lag - ahead, history)
		head[2] = not bool(head[2])
	# Walk back from the front buffer: each car's front then rear axle,
	# measured as straight lines so the wheelbase and couplings keep their
	# length round bends.
	var cur := [head[0], head[1], not bool(head[2]), 0.0]
	var cars: Array = (s["node"] as Node3D).get_children()
	var front_point := paths.point(head[0], head[1])
	var odo: float = s["odo"]
	var prev_head: Vector3 = s["head"]
	if prev_head != Vector3.INF:
		var step := front_point.distance_to(prev_head)
		if step < MAX_LAG:
			odo += step
	s["head"] = front_point
	s["odo"] = odo
	var near := cam == null or cam.global_position.distance_to(front_point) < draw_distance
	var xfs: Array[Transform3D] = []
	s["xfs"] = xfs
	var coupler := front_point # the buffer the next car couples to
	var reach := 0.0 # its distance ahead of the next car's front buffer
	for i in cars.size():
		var model := loco if i == 0 else wagon
		# Front axle at a straight `reach` + overhang from the coupler, rear
		# axle a wheelbase behind it. (Round a sharp bend the buffers of two
		# cars open up a little, as the rails have no curve there.)
		cur = _chord_back(cur, coupler, reach + model.axle_front - model.front, history)
		var pf := paths.point(cur[0], cur[1])
		cur = _chord_back(cur, pf, model.axle_back - model.axle_front, history)
		var pr := paths.point(cur[0], cur[1])
		var dir := pf - pr
		if dir.length() < 0.01:
			dir = Vector3.FORWARD
		dir = dir.normalized()
		# Origin: the front axle sits at local z = axle_front.
		var xf := Transform3D(Basis.looking_at(dir, Vector3.UP), pf + dir * model.axle_front)
		(cars[i] as Node3D).transform = xf
		xfs.append(xf)
		if near:
			_draw(model, xf, odo)
		# On to the rear buffer, where the next car couples.
		cur = paths.advance(cur[0], cur[1], cur[2], model.back - model.axle_back, history)
		coupler = xf * Vector3(0.0, 0.0, model.back)
		reach = COUPLING_GAP


## Moves on from rail position `from` until the straight distance to `to`
## is `dist` (a few steps: along a bend the rails are longer than the chord).
func _chord_back(from: Array, to: Vector3, dist: float, prefer: Array) -> Array:
	var cur := from
	for k in 8:
		var short := dist - paths.point(cur[0], cur[1]).distance_to(to)
		if short < 0.001:
			break
		cur = paths.advance(cur[0], cur[1], cur[2], short, prefer)
		if float(cur[3]) > 0.0:
			break # end of the line
	return cur


## Adds one car to the parts' instance lists.
func _draw(model: Model, xf: Transform3D, odo: float) -> void:
	for part in model.parts:
		var local := part.rest
		if part.wheel_radius > 0.0:
			# Rolling forward (-Z) turns the wheel's top forward.
			local = local * Transform3D(Basis(Vector3.RIGHT, -odo / part.wheel_radius), Vector3.ZERO)
		elif part.crank > 0.0:
			var a := odo / model.driver_radius
			local.origin += Vector3(0.0, part.crank * (cos(a) - 1.0), -part.crank * sin(a))
		var mm := part.instances.multimesh
		mm.set_instance_transform(part.used, xf * local)
		part.used += 1


## Makes room for `count` cars of `model` (the instance data is refilled
## every frame, so growing may drop it) and starts a new frame.
static func _reserve(model: Model, count: int) -> void:
	for part in model.parts:
		part.used = 0
		var mm := part.instances.multimesh
		if mm.instance_count < count:
			var size := maxi(mm.instance_count, 16)
			while size < count:
				size *= 2
			mm.visible_instance_count = 0
			mm.instance_count = size


## Loads a vehicle model and prepares one MultiMesh per part. Without the
## file (for example a clone without Git LFS) a painted box stands in.
func _load_model(path: String, prefix: String, fallback: Color, length: float) -> Model:
	var model := Model.new()
	var scene: PackedScene = null
	if ResourceLoader.exists(path):
		scene = load(path) as PackedScene
	var meshes: Array[Dictionary] = []
	if scene != null:
		var template := scene.instantiate() as Node3D
		template.visible = false
		# In the tree for a moment so ArtStyle repaints its materials.
		add_child(template)
		for mi: MeshInstance3D in template.find_children("*", "MeshInstance3D", true, false):
			if mi.mesh == null:
				continue
			var rest := mi.transform
			var p := mi.get_parent()
			while p != template and p is Node3D:
				rest = (p as Node3D).transform * rest
				p = p.get_parent()
			meshes.append({"name": String(mi.name), "mesh": _painted_mesh(mi), "rest": rest})
		remove_child(template)
		template.free()
	if meshes.is_empty():
		push_warning("Trains: %s missing, drawing boxes (run git lfs pull)" % path)
		var box := BoxMesh.new()
		box.size = Vector3(2.9, 3.4, length)
		var mat := StandardMaterial3D.new()
		mat.resource_name = "M_%s_Placeholder" % prefix
		mat.albedo_color = fallback
		box.material = mat
		meshes.append({"name": "Body", "mesh": box,
				"rest": Transform3D(Basis.IDENTITY, Vector3(0.0, 2.1, 0.0))})
		model.front = -length * 0.5
		model.back = length * 0.5
		model.axle_front = model.front + 1.5
		model.axle_back = model.back - 1.5
	else:
		model.front = INF
		model.back = -INF
		model.axle_front = INF
		model.axle_back = -INF
	for m in meshes:
		var part := Part.new()
		part.name = m["name"]
		part.rest = m["rest"]
		var mesh: Mesh = m["mesh"]
		var aabb := part.rest * mesh.get_aabb()
		if part.name.begins_with("Wheelset"):
			part.wheel_radius = aabb.size.y * 0.5
			model.axle_front = minf(model.axle_front, part.rest.origin.z)
			model.axle_back = maxf(model.axle_back, part.rest.origin.z)
			if part.name.contains("Driver"):
				model.driver_radius = part.wheel_radius
		elif part.name == "SideRods":
			part.crank = 0.28
		if part.name == "Body" and scene != null:
			model.front = aabb.position.z
			model.back = aabb.end.z
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s_%s" % [prefix, part.name]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = 16
		mm.visible_instance_count = 0
		mmi.multimesh = mm
		if part.wheel_radius > 0.0 or part.crank > 0.0:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
		part.instances = mmi
		model.parts.append(part)
	if model.axle_front == INF:
		model.axle_front = model.front + 1.5
		model.axle_back = model.back - 1.5
	return model


## The mesh of `mi` carrying the materials it shows now (after ArtStyle's
## repaint), since a MultiMesh has no per-surface material overrides.
static func _painted_mesh(mi: MeshInstance3D) -> Mesh:
	var mesh := mi.mesh
	var changed := false
	for i in mesh.get_surface_count():
		if mi.get_surface_override_material(i) != null:
			changed = true
	if mi.material_override == null and not changed:
		return mesh
	var copy := mesh.duplicate() as Mesh
	for i in copy.get_surface_count():
		var mat := mi.material_override
		if mat == null:
			mat = mi.get_surface_override_material(i)
		if mat != null:
			copy.surface_set_material(i, mat)
	return copy
