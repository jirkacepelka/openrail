extends Node3D
## Towns, stations and trains, with floating labels for them. Towns are
## drawn by `world/towns.gd` (streets, buildings, fields) with a name and
## population label over the centre, stations by `world/stations.gd` (the
## station model beside the track) with the number of waiting passengers,
## and trains by `world/trains.gd` (a steam locomotive and wagons on the
## rails) with their load. Labels refresh a few times per second from the sim
## getters; trains move every frame.
## Sim (x, y) maps to Godot (x, z); everything sits on the terrain.

const Loc := preload("res://game/loc.gd")
const Towns := preload("res://world/towns.gd")
const Trains := preload("res://world/trains.gd")
const Stations := preload("res://world/stations.gd")
const Ground := preload("res://world/ground.gd")

const TOWN_LABEL_HEIGHT := 75.0 ## Above the ground at the town centre (m).
const STATION_LABEL_HEIGHT := 30.0 ## Above the rail top at the station (m).
const TRAIN_LABEL_HEIGHT := 18.0 ## Above the middle of the train (m).

const REFRESH_SECONDS := 0.25

var sim: SimWorld

var towns: Towns
var trains: Trains
var stations: Stations
var _town_labels: Array[Label3D] = []
var _station_labels := {} ## node id -> Label3D
var _train_labels := {} ## train id -> Label3D
var _capacity := 100
var _timer := 0.0


func setup(p_sim: SimWorld) -> void:
	sim = p_sim
	if towns == null:
		towns = Towns.new()
		towns.name = "Towns"
		add_child(towns)
		trains = Trains.new()
		trains.name = "Trains"
		add_child(trains)
		stations = Stations.new()
		stations.name = "Stations"
		add_child(stations)
	towns.setup(sim)
	trains.setup(sim)
	stations.setup(sim, trains.paths, trains.train_length())
	_capacity = sim.train_capacity()
	refresh()


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= REFRESH_SECONDS:
		_timer = 0.0
		refresh()
	_move_train_labels()


func refresh() -> void:
	if sim == null:
		return
	trains.sync()
	stations.sync()
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
	# Drawn after transparent full-screen passes (the art style's
	# post-process quad), which would otherwise paint over it.
	l.render_priority = 127
	l.outline_render_priority = 126
	return l


func _refresh_towns() -> void:
	towns.sync()
	var pos := sim.town_positions()
	var names := sim.town_names()
	var pops := sim.town_populations()
	while _town_labels.size() < pos.size():
		var label := _make_label(44, Color(1, 0.97, 0.9))
		label.outline_size = 14
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
		if not _station_labels.has(id):
			var label := _make_label(32, Color(0.75, 0.9, 1.0))
			add_child(label)
			_station_labels[id] = label
		var label: Label3D = _station_labels[id]
		var station := stations.station_node(id)
		var base := Ground.height_at(sim, n["x"], n["y"])
		if station != null and station.get_child_count() > 0:
			base = (station.get_child(0) as Node3D).position.y
		label.position = Vector3(n["x"], base + STATION_LABEL_HEIGHT, n["y"])
		label.text = Loc.t("station.waiting", [Loc.number(sim.station_waiting(id))])
	for id: int in _station_labels.keys():
		if not seen.has(id):
			(_station_labels[id] as Node).queue_free()
			_station_labels.erase(id)


func _refresh_trains() -> void:
	var seen := {}
	for t in sim.trains():
		var id: int = t["id"]
		seen[id] = true
		if not _train_labels.has(id):
			var label := _make_label(30, Color(1, 0.95, 0.8))
			add_child(label)
			_train_labels[id] = label
		(_train_labels[id] as Label3D).text = Loc.t("train.load",
				[id, sim.train_load(id), _capacity])
	for id: int in _train_labels.keys():
		if not seen.has(id):
			(_train_labels[id] as Node).queue_free()
			_train_labels.erase(id)
	_move_train_labels()


func _move_train_labels() -> void:
	for id: int in _train_labels:
		var at: Variant = trains.train_position(id)
		if at is Vector3:
			(_train_labels[id] as Node3D).position = (at as Vector3) + Vector3(0.0, TRAIN_LABEL_HEIGHT, 0.0)
