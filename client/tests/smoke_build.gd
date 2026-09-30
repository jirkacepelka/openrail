extends SceneTree
## Headless smoke test for the build tools: builds a line, two stations and
## a train through BuildController, routes the train and checks it moves.
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

	print("SMOKE %s (%d failures)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _click(controller: Node, x: float, y: float) -> void:
	controller.set("_ground", Vector2(x, y))
	controller.set("_has_ground", true)
	controller.call("_click")


func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		failures += 1
