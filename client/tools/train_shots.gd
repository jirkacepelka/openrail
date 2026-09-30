extends SceneTree
## Screenshots of a train and a station close up, for checking how the
## vehicle and station models sit on the rails and the land. Builds a line
## between the two closest towns (station plot to station plot, with a bend
## halfway), a station at each end and a routed train, runs it, and takes
## shots of the train on the bend and of the far station with the train in.
##
##   xvfb-run -a -s "-screen 0 1920x1080x24" godot --path client \
##       --script res://tools/train_shots.gd -- --out /tmp/train
##
## Saves <out>_bend_35.png, _bend_80.png, _bend_250.png and the same for
## _station_ (distances in metres). --seed / --towns: the world; --bend: sideways
## offset of the bend in metres (default: the hilliest of a few).

const Tools := preload("res://gameplay/tools.gd")

var _args := {}
var _session: Node
var _game: Node
var _sim: SimWorld
var _cam: Camera3D
var _trains: Node
var _train := -1
var _bend := Vector2.ZERO
var _far_station := Vector2.ZERO
var _phase := "run_to_bend"
var _shots: Array = [] ## [name, distance, pitch deg, yaw offset deg]
var _wait := 0
var _still := 0
var _last := Vector2.INF
var _focus := Vector3.ZERO
var _dir := Vector3.FORWARD
var _ticks := 0


func _initialize() -> void:
	_args = _parse(OS.get_cmdline_user_args())
	_session = root.get_node("Session")
	_session.set("change_scenes", false)
	_session.call("start_local", int(_args.get("seed", "1")), int(_args.get("towns", "6")))
	_game = load("res://game/game.tscn").instantiate()
	root.add_child(_game)
	_sim = _session.get("world")
	(_game.get_node("Camera3D") as Camera3D).set_process(false)
	_cam = Camera3D.new()
	_cam.name = "ShotCamera"
	_game.add_child(_cam)
	_cam.make_current()
	_cam.far = 20000.0
	_cam.near = 0.3


func _build() -> void:
	var labels: Node = _game.get("labels")
	_trains = labels.get("trains")
	var towns: Node = labels.get("towns")
	var pos := _sim.town_positions()
	var a := 0
	var b := 1
	var best := INF
	for i in pos.size():
		for j in range(i + 1, pos.size()):
			if pos[i].distance_to(pos[j]) < best:
				best = pos[i].distance_to(pos[j])
				a = i
				b = j
	var ends: Array[Vector2] = []
	var outs: Array[Vector2] = []
	for i: int in [a, b]:
		var plot: Dictionary = towns.call("layout", i)["station_plot"]
		var c: Vector2 = plot["pos"]
		var ax := Vector2.from_angle(plot["angle"])
		var other := pos[b] if i == a else pos[a]
		if ax.dot(other - c) < 0.0:
			ax = -ax
		ends.append(c)
		outs.append(c + ax * 150.0)
	var mid := (outs[0] + outs[1]) * 0.5
	var side := (outs[1] - outs[0]).normalized().orthogonal()
	var offset := String(_args.get("bend", "auto"))
	if offset == "auto":
		# The hilliest of a few bends, to see the train on a slope.
		var best_climb := -1.0
		for o: float in [-700.0, -450.0, -250.0, 250.0, 450.0, 700.0]:
			var p := mid + side * o
			var climb := absf(_sim.terrain_height(p.x, p.y) - _sim.terrain_height(outs[0].x, outs[0].y))
			if climb > best_climb:
				best_climb = climb
				_bend = p
	else:
		_bend = mid + side * float(offset)
	var pts: Array[Vector2] = [ends[0], outs[0], _bend, outs[1], ends[1]]
	var controller: Node = _game.get("gameplay").get("controller")
	controller.set_process(false)
	controller.set_process_unhandled_input(false)
	controller.call("set_tool", Tools.Tool.TRACK)
	for p in pts:
		_click(controller, p)
	controller.call("cancel")
	controller.call("set_tool", Tools.Tool.STATION)
	_click(controller, ends[0])
	_click(controller, ends[1])
	controller.call("set_tool", Tools.Tool.TRAIN)
	_click(controller, ends[0].lerp(outs[0], 0.5))
	for t in _sim.trains():
		_train = t["id"]
	controller.call("set_tool", Tools.Tool.ROUTE)
	controller.set("selected_train", _train)
	_click(controller, ends[1])
	_click(controller, ends[0])
	controller.call("confirm_route")
	controller.call("cancel")
	_far_station = ends[1]
	_session.call("set_speed", 0)
	labels.call("refresh")
	print("train_shots: towns %d and %d, bend at %s, train %d" % [a, b, _bend, _train])


func _process(delta: float) -> bool:
	if _sim == null:
		return false
	if _train < 0:
		_build()
		return false
	match _phase:
		"run_to_bend":
			_advance(2)
			var cars: Array = _trains.call("cars_of", _train)
			if not cars.is_empty():
				var mid := cars[cars.size() / 2] as Node3D
				if Vector2(mid.position.x, mid.position.z).distance_to(_bend) < 6.0:
					_start_shots("bend", mid)
			if _ticks > 40000:
				push_error("train never reached the bend")
				return true
		"run_to_station":
			_advance(4)
			var p := Vector2.INF
			for t in _sim.trains():
				if t["id"] == _train:
					p = Vector2(t["x"], t["y"])
			_still = _still + 1 if p == _last else 0
			_last = p
			if p.distance_to(_far_station) < 1.0 and _still > 30:
				var cars: Array = _trains.call("cars_of", _train)
				_start_shots("station", cars[cars.size() / 2] as Node3D)
		"shoot":
			_shoot()
			if _shots.is_empty():
				if _phase == "done_bend":
					pass
			return _phase == "done"
		"done_bend":
			_phase = "run_to_station"
	return false


func _advance(ticks: int) -> void:
	_session.call("advance_ticks", ticks)
	_ticks += ticks
	# Follow the train with the camera meanwhile.
	var at: Variant = _trains.call("train_position", _train)
	if at is Vector3:
		_cam.look_at_from_position((at as Vector3) + Vector3(60, 45, 60), at)


var _next_phase := ""


func _start_shots(kind: String, car: Node3D) -> void:
	_focus = car.global_position + Vector3(0.0, 2.0, 0.0)
	_dir = -car.global_transform.basis.z
	_dir.y = 0.0
	_dir = _dir.normalized()
	_shots = [[kind + "_35", 35.0, 14.0, 70.0], [kind + "_80", 80.0, 22.0, 60.0],
			[kind + "_250", 250.0, 35.0, 50.0]]
	if kind == "station":
		_shots = [[kind + "_35", 35.0, 18.0, 120.0], [kind + "_80", 80.0, 25.0, 115.0],
				[kind + "_250", 250.0, 38.0, 125.0]]
	_next_phase = "run_to_station" if kind == "bend" else "done"
	_phase = "shoot"
	_wait = 30


func _shoot() -> void:
	var s: Array = _shots[0]
	var yaw := deg_to_rad(float(s[3]))
	var pitch := deg_to_rad(float(s[2]))
	var flat := _dir.rotated(Vector3.UP, yaw)
	var off := (flat * cos(pitch) + Vector3.UP * sin(pitch)) * float(s[1])
	_cam.look_at_from_position(_focus + off, _focus)
	_wait -= 1
	if _wait > 0:
		return
	var out := "%s_%s.png" % [_args.get("out", "/tmp/train"), s[0]]
	root.get_viewport().get_texture().get_image().save_png(out)
	print("train_shots: saved ", out)
	_shots.pop_front()
	_wait = 20
	if _shots.is_empty():
		_phase = _next_phase


func _click(controller: Node, p: Vector2) -> void:
	controller.set("_ground", p)
	controller.set("_has_ground", true)
	controller.call("_click")


func _parse(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < argv.size():
		var a := argv[i]
		if a.begins_with("--") and i + 1 < argv.size():
			out[a.substr(2)] = argv[i + 1]
			i += 2
		else:
			i += 1
	return out
