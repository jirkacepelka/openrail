extends Node3D
## Towns, plus markers and floating labels for towns, stations and trains.
## Towns are drawn by `world/towns.gd` (streets, buildings, fields) with a
## name and population label over the centre; stations and trains are simple
## meshes. Refreshed a few times per second from the sim getters.
## Sim (x, y) maps to Godot (x, z).

const Loc := preload("res://game/loc.gd")
const Towns := preload("res://world/towns.gd")
const Ground := preload("res://world/ground.gd")

const TOWN_LABEL_HEIGHT := 75.0 ## Above the ground at the town centre (m).

const REFRESH_SECONDS := 0.25

var sim: SimWorld

var towns: Towns
var _town_labels: Array[Label3D] = []
var _stations := {} ## node id -> {marker, label}
var _trains := {} ## train id -> {box, label}
var _capacity := 100
var _timer := 0.0


func setup(p_sim: SimWorld) -> void:
	sim = p_sim
	if towns == null:
		towns = Towns.new()
		towns.name = "Towns"
		add_child(towns)
	towns.setup(sim)
	_capacity = sim.train_capacity()
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


static func _make_marker(mesh: Mesh, color: Color) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	m.material_override = mat
	return m


func _refresh_towns() -> void:
	towns.sync()
	var pos := sim.town_positions()
	var names := sim.town_names()
	var pops := sim.town_populations()
	while _town_labels.size() < pos.size():
		var label := _make_label(44, Color(1, 0.97, 0.9))
		label.outline_size = 14
		# Drawn after transparent full-screen passes (the art style's
		# post-process quad), which would otherwise paint over it.
		label.render_priority = 127
		label.outline_render_priority = 126
		add_child(label)
		_town_labels.append(label)
	while _town_labels.size() > pos.size():
		_town_labels.pop_back().queue_free()
	for i in pos.size():
		var label := _town_labels[i]
		label.text = Loc.t("town.label", [names[i], Loc.number(pops[i])])
		var ground := Ground.height_at(sim, pos[i].x, pos[i].y)
		label.position = Vector3(pos[i].x, ground + TOWN_LABEL_HEIGHT, pos[i].y)


func _refresh_stations() -> void:
	var seen := {}
	for n in sim.nodes():
		if not n["station"]:
			continue
		var id: int = n["id"]
		seen[id] = true
		if not _stations.has(id):
			var marker := _make_marker(BoxMesh.new(), Color(0.25, 0.62, 0.95))
			(marker.mesh as BoxMesh).size = Vector3(40, 14, 40)
			add_child(marker)
			var label := _make_label(32, Color(0.75, 0.9, 1.0))
			add_child(label)
			_stations[id] = {"marker": marker, "label": label}
		var s: Dictionary = _stations[id]
		(s["marker"] as MeshInstance3D).position = Vector3(n["x"], 7.0, n["y"])
		var label: Label3D = s["label"]
		label.position = Vector3(n["x"], 60.0, n["y"])
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
			var box := _make_marker(BoxMesh.new(), Color.from_hsv(fmod(id * 0.618, 1.0), 0.8, 0.85))
			(box.mesh as BoxMesh).size = Vector3(60, 12, 12)
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
		if _trains.has(id):
			var p := Vector3(t["x"], 6.0, t["y"])
			(_trains[id]["box"] as Node3D).position = p
			(_trains[id]["label"] as Node3D).position = p + Vector3(0, 45, 0)
