extends Node3D
## Markers and floating labels for towns, stations and trains. Simple meshes
## and Label3D nodes; refreshed a few times per second from the sim getters.
## Sim (x, y) maps to Godot (x, z); everything sits on the terrain, trains
## on the rails (see world/track_mesh.gd) and pitched along the slope.

const Loc := preload("res://game/loc.gd")
const Ground := preload("res://world/ground.gd")
const TrackMesh := preload("res://world/track_mesh.gd")

## Height of the rail top above the track base.
const RAIL_TOP := TrackMesh.BED_TOP + TrackMesh.SLEEPER_SIZE.y + TrackMesh.RAIL_HEIGHT
const CAR_LENGTH := 18.0
const CAR_GAP := 1.2
const CARS := 3
const CAR_SIZE := Vector3(3.0, 3.9, CAR_LENGTH) ## Width, height, length.

const REFRESH_SECONDS := 0.25

var sim: SimWorld

var _towns: Array[Dictionary] = [] ## {marker, label}
var _stations := {} ## node id -> {marker, label}
var _trains := {} ## train id -> {box, label}
var _capacity := 100
var _timer := 0.0
var _water := 0.0
var _track_ends := {} ## track id -> [Vector2 a, Vector2 b]


func setup(p_sim: SimWorld) -> void:
	sim = p_sim
	_capacity = sim.train_capacity()
	_water = sim.terrain_water_level()
	refresh()


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= REFRESH_SECONDS:
		_timer = 0.0
		refresh()
	_move_trains()


func refresh() -> void:
	if sim == null:
		return
	_refresh_tracks()
	_refresh_towns()
	_refresh_stations()
	_refresh_trains()


static func _make_label(font_size: int, color: Color) -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.fixed_size = true
	l.no_depth_test = true
	l.pixel_size = 0.001
	l.font_size = font_size
	l.outline_size = 10
	l.modulate = color
	l.outline_modulate = Color(0, 0, 0, 0.85)
	return l


## Height of the track base (under the ballast) at world (x, z).
func _track_base(x: float, z: float) -> float:
	return maxf(Ground.height_at(sim, x, z), _water + TrackMesh.WATER_CLEARANCE)


func _refresh_tracks() -> void:
	var pos := {}
	for n in sim.nodes():
		pos[n["id"]] = Vector2(n["x"], n["y"])
	_track_ends.clear()
	for t in sim.tracks():
		_track_ends[t["id"]] = [pos[t["a"]], pos[t["b"]]]


## Unit direction of the first track at `node_pos`, or +x.
func _dir_at(node_pos: Vector2) -> Vector2:
	for ends: Array in _track_ends.values():
		var a: Vector2 = ends[0]
		var b: Vector2 = ends[1]
		if a.distance_to(node_pos) < 0.5 or b.distance_to(node_pos) < 0.5:
			return (b - a).normalized()
	return Vector2.RIGHT


static func _make_marker(mesh: Mesh, color: Color) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	m.material_override = mat
	return m


func _refresh_towns() -> void:
	var pos := sim.town_positions()
	var names := sim.town_names()
	var pops := sim.town_populations()
	while _towns.size() < pos.size():
		var marker := _make_marker(CylinderMesh.new(), Color(0.86, 0.80, 0.68))
		add_child(marker)
		var label := _make_label(40, Color(1, 1, 1))
		add_child(label)
		_towns.append({"marker": marker, "label": label})
	for i in pos.size():
		var t := _towns[i]
		var pop: int = pops[i]
		var radius := 60.0 + sqrt(float(pop)) * 3.5 # about 200 to 300 m
		var cyl := (t["marker"] as MeshInstance3D).mesh as CylinderMesh
		cyl.top_radius = radius
		cyl.bottom_radius = radius
		# A thick disc whose top is just above the highest ground it covers.
		cyl.height = 40.0
		var ground := Ground.height_at(sim, pos[i].x, pos[i].y)
		var top := ground
		var ring := PackedVector2Array()
		for k in 12:
			var ang := TAU * k / 12.0
			for f in [0.5, 1.0]:
				ring.append(pos[i] + Vector2(cos(ang), sin(ang)) * radius * float(f))
		for h in sim.terrain_heights_at(ring):
			top = maxf(top, h)
		var marker := t["marker"] as MeshInstance3D
		marker.position = Vector3(pos[i].x, top + 0.4 - cyl.height * 0.5, pos[i].y)
		var label: Label3D = t["label"]
		label.text = Loc.t("town.label", [names[i], Loc.number(pop)])
		label.position = Vector3(pos[i].x, ground + 90.0, pos[i].y)


func _refresh_stations() -> void:
	var seen := {}
	for n in sim.nodes():
		if not n["station"]:
			continue
		var id: int = n["id"]
		seen[id] = true
		if not _stations.has(id):
			var marker := _make_station()
			add_child(marker)
			var label := _make_label(32, Color(0.75, 0.9, 1.0))
			add_child(label)
			_stations[id] = {"marker": marker, "label": label}
		var s: Dictionary = _stations[id]
		var p := Vector2(n["x"], n["y"])
		var base := _track_base(p.x, p.y)
		var dir := _dir_at(p)
		var marker := s["marker"] as Node3D
		marker.position = Vector3(p.x, base, p.y)
		marker.rotation = Vector3(0.0, atan2(-dir.y, dir.x), 0.0)
		var label: Label3D = s["label"]
		label.position = Vector3(p.x, base + 50.0, p.y)
		label.text = Loc.t("station.waiting", [Loc.number(sim.station_waiting(id))])
	for id: int in _stations.keys():
		if not seen.has(id):
			(_stations[id]["marker"] as Node).queue_free()
			(_stations[id]["label"] as Node).queue_free()
			_stations.erase(id)


func _refresh_trains() -> void:
	var seen := {}
	for t in sim.trains():
		var id: int = t["id"]
		seen[id] = true
		if not _trains.has(id):
			var box := _make_train(Color.from_hsv(fmod(id * 0.618, 1.0), 0.8, 0.85))
			add_child(box)
			var label := _make_label(30, Color(1, 0.95, 0.8))
			add_child(label)
			_trains[id] = {"box": box, "label": label}
		(_trains[id]["label"] as Label3D).text = Loc.t("train.load",
				[id, sim.train_load(id), _capacity])
	for id: int in _trains.keys():
		if not seen.has(id):
			(_trains[id]["box"] as Node).queue_free()
			(_trains[id]["label"] as Node).queue_free()
			_trains.erase(id)
	_move_trains()


func _move_trains() -> void:
	if sim == null or _trains.is_empty():
		return
	for t in sim.trains():
		var id: int = t["id"]
		if not _trains.has(id):
			continue
		var p := Vector2(t["x"], t["y"])
		var dir := Vector2.RIGHT
		var ends: Array = _track_ends.get(t["track"], [])
		if not ends.is_empty():
			dir = ((ends[1] as Vector2) - (ends[0] as Vector2)).normalized()
		# Pitch from the rail height at both ends of the train.
		var half := (CAR_LENGTH * CARS + CAR_GAP * (CARS - 1)) * 0.5
		var front := p + dir * half
		var back := p - dir * half
		var yf := _track_base(front.x, front.y)
		var yb := _track_base(back.x, back.y)
		var y := (yf + yb) * 0.5 + RAIL_TOP
		var body := _trains[id]["box"] as Node3D
		body.position = Vector3(p.x, y, p.y)
		var fwd := Vector3(front.x - back.x, yf - yb, front.y - back.y).normalized()
		body.basis = Basis.looking_at(fwd, Vector3.UP)
		(_trains[id]["label"] as Node3D).position = Vector3(p.x, y + 30.0, p.y)


## A platform with a shelter, along local +x (the track), beside the track.
func _make_station() -> Node3D:
	var root := Node3D.new()
	var platform := _make_marker(BoxMesh.new(), Color(0.72, 0.68, 0.6))
	(platform.mesh as BoxMesh).size = Vector3(80.0, 1.0, 6.0)
	platform.position = Vector3(0.0, 0.1, -6.0)
	root.add_child(platform)
	var shelter := _make_marker(BoxMesh.new(), Color(0.25, 0.62, 0.95))
	(shelter.mesh as BoxMesh).size = Vector3(22.0, 5.0, 5.0)
	shelter.position = Vector3(0.0, 3.1, -7.5)
	root.add_child(shelter)
	return root


## A short train of CARS boxes along local -z (Basis.looking_at's forward).
func _make_train(color: Color) -> Node3D:
	var root := Node3D.new()
	var total := CAR_LENGTH * CARS + CAR_GAP * (CARS - 1)
	for i in CARS:
		var col := color.darkened(0.35) if i == 0 else color
		var car := _make_marker(BoxMesh.new(), col)
		(car.mesh as BoxMesh).size = CAR_SIZE
		var z := -total * 0.5 + CAR_LENGTH * 0.5 + i * (CAR_LENGTH + CAR_GAP)
		car.position = Vector3(0.0, CAR_SIZE.y * 0.5 + 0.3, z)
		root.add_child(car)
	return root
