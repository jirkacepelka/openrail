extends SceneTree
## Headless smoke test for the build tools: builds a line, two stations and
## a train through BuildController, routes the train and checks it moves.
## Then builds a bent, hilly line and checks the train is drawn as a
## locomotive and wagons whose wheels stay on the rails all the way.
## Run: godot --headless --path client --script res://tests/smoke_build.gd

const Tools := preload("res://gameplay/tools.gd")

var failures := 0


func _initialize() -> void:
	var main: Node = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	var sim: SimWorld = main.get("sim")
	var controller: Node = main.get("gameplay").get("controller")
	controller.set_process(false)
	controller.set_process_unhandled_input(false)

	var nodes_before := sim.nodes().size()
	var tracks_before := sim.tracks().size()
	var trains_before := sim.trains().size()

	controller.set_tool(Tools.Tool.TRACK)
	_click(controller, 5000, 5000)
	_click(controller, 7000, 5000)
	_click(controller, 9000, 5000)
	controller.cancel()
	_check(sim.nodes().size() == nodes_before + 3, "track tool built 3 nodes")
	_check(sim.tracks().size() == tracks_before + 2, "track tool built 2 tracks")

	controller.set_tool(Tools.Tool.STATION)
	_click(controller, 5000, 5000)
	_click(controller, 9000, 5000)
	var stations := 0
	for n in sim.nodes():
		if n["station"] and n["x"] >= 4999.0:
			stations += 1
	_check(stations == 2, "station tool built 2 stations")

	controller.set_tool(Tools.Tool.TRAIN)
	_click(controller, 6000, 5000)
	_check(sim.trains().size() == trains_before + 1, "train tool placed a train")

	controller.set_tool(Tools.Tool.ROUTE)
	_click(controller, 5000, 5000) # selects the train standing there
	_check(controller.get("selected_train") >= 0, "route tool selected the train")
	_click(controller, 9000, 5000)
	_click(controller, 5000, 5000)
	_check(controller.can_confirm_route(), "route has stops to confirm")
	controller.confirm_route()

	var train_id: int = controller.get("selected_train")
	var max_x := 0.0
	for i in 3000:
		sim.step()
		for t in sim.trains():
			if t["x"] >= 4999.0 and t["y"] >= 4999.0:
				max_x = maxf(max_x, t["x"])
	_check(max_x > 8900.0, "routed train reached the far station (max x %.0f)" % max_x)

	await _check_train_models(main, sim, controller)

	print("SMOKE %s (%d failures)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


## A line with a sharp bend over hills (a station at each end), a routed
## train, and its cars checked against the rails while it runs.
func _check_train_models(main: Node, sim: SimWorld, controller: Node) -> void:
	var trains: Node = main.get("labels").get("trains")
	var stations: Node = main.get("labels").get("stations")
	var pts := [Vector2(12000, 12000), Vector2(12700, 12000), Vector2(13200, 12450),
			Vector2(13300, 13100)]
	controller.set_tool(Tools.Tool.TRACK)
	for p: Vector2 in pts:
		_click(controller, p.x, p.y)
	controller.cancel()
	controller.set_tool(Tools.Tool.STATION)
	_click(controller, pts[0].x, pts[0].y)
	_click(controller, pts[3].x, pts[3].y)
	controller.set_tool(Tools.Tool.TRAIN)
	var before := {}
	for t in sim.trains():
		before[t["id"]] = true
	_click(controller, 12300, 12000)
	var id := -1
	for t in sim.trains():
		if not before.has(t["id"]):
			id = t["id"]
	_check(id >= 0, "train placed on the bent line")
	controller.set_tool(Tools.Tool.ROUTE)
	controller.set("selected_train", id)
	_click(controller, pts[3].x, pts[3].y)
	_click(controller, pts[0].x, pts[0].y)
	controller.confirm_route()
	controller.cancel()
	trains.set("draw_distance", INF) # the camera is at the first town
	main.get("labels").call("refresh")
	await process_frame

	var start := stations.call("station_node", sim.nearest_node(pts[0].x, pts[0].y, 1.0)) as Node3D
	_check(start != null and start.find_child("Building", true, false) != null,
			"station model stands at the station node")
	var cars: Array = trains.call("cars_of", id)
	_check(cars.size() >= 3 and cars[0].name == "Loco", "train drawn as a locomotive and %d wagons"
			% (cars.size() - 1))
	var loco_body := trains.find_child("Loco_Body", false, false) as MultiMeshInstance3D
	_check(loco_body != null and loco_body.multimesh.visible_instance_count >= 1,
			"locomotive body instanced")
	var paths: RefCounted = trains.get("paths")
	var loco: RefCounted = trains.get("loco")
	var wagon: RefCounted = trains.get("wagon")
	var worst_axle := 0.0
	var worst_height := 0.0
	var worst_gap := 0.0
	var bend_gap := 0.0
	var prev_dir := Vector3.ZERO
	var min_gap := INF
	var reached := 0.0
	var pitched := 0.0
	for i in 2400:
		sim.step()
		if i % 4 != 0:
			continue
		trains.call("update", 0.1)
		cars = trains.call("cars_of", id)
		var prev_back := Vector3.INF
		for c in cars.size():
			var model: RefCounted = loco if c == 0 else wagon
			var xf: Transform3D = (cars[c] as Node3D).global_transform
			for z: float in [model.get("axle_front"), model.get("axle_back")]:
				var p := xf * Vector3(0.0, 0.0, z)
				var off := _off_track(paths, p)
				worst_axle = maxf(worst_axle, off.x)
				worst_height = maxf(worst_height, off.y)
			var front := xf * Vector3(0.0, 0.0, model.get("front"))
			if prev_back != Vector3.INF:
				var gap := front.distance_to(prev_back)
				min_gap = minf(min_gap, gap)
				if xf.basis.z.normalized().dot(prev_dir) > 0.9999:
					worst_gap = maxf(worst_gap, gap) # in line
				else:
					bend_gap = maxf(bend_gap, gap) # round a sharp corner
			prev_dir = xf.basis.z.normalized()
			prev_back = xf * Vector3(0.0, 0.0, model.get("back"))
			pitched = maxf(pitched, absf(xf.basis.z.normalized().y))
		reached = maxf(reached, (cars[0] as Node3D).position.z)
	_check(worst_axle < 0.05, "wheels stay on the rails (worst %.3f m sideways)" % worst_axle)
	_check(worst_height < 0.05, "wheels stay on the rail top (worst %.3f m)" % worst_height)
	_check(min_gap > 0.2 and worst_gap < 0.3 and bend_gap < 2.0,
			"cars keep their spacing (%.2f to %.2f m, %.2f m round the corner)"
			% [min_gap, worst_gap, bend_gap])
	_check(reached > 13000.0, "train ran round the bend (z %.0f)" % reached)
	_check(pitched > 0.005, "cars pitch on slopes (max %.3f)" % pitched)


## Sideways and vertical distance of `p` from the nearest rail centre line.
func _off_track(paths: RefCounted, p: Vector3) -> Vector2:
	var best := Vector2(INF, INF)
	var tracks: Dictionary = paths.get("tracks")
	for id: int in tracks:
		var t: Dictionary = tracks[id]
		var d: float = paths.call("distance_on", id, Vector2(p.x, p.z))
		var q: Vector3 = paths.call("point", id, d)
		var side := Vector2(q.x - p.x, q.z - p.z).length()
		if side < best.x:
			best = Vector2(side, absf(q.y - p.y))
	return best


func _click(controller: Node, x: float, y: float) -> void:
	controller.set("_ground", Vector2(x, y))
	controller.set("_has_ground", true)
	controller.call("_click")


func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		failures += 1
