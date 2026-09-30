extends SceneTree
## Screenshots of the game on the terrain: the start view, then a short line
## built from the first town, seen close up and from high above.
##
##   xvfb-run -a -s "-screen 0 1920x1080x24" godot --path client \
##       --script res://tools/terrain_shots.gd -- --out-dir /tmp/shots
##
## Saves start.png, line_close.png, overview.png and hills.png into --out-dir.

const Tools := preload("res://gameplay/tools.gd")
const Ground := preload("res://world/ground.gd")

var _out_dir := "user://"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size() - 1:
		if args[i] == "--out-dir":
			_out_dir = args[i + 1]
	_run.call_deferred()


func _run() -> void:
	var main: Node = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	var sim: SimWorld = main.get("sim")
	var camera: Camera3D = main.get_node("Camera3D")
	var terrain: Node = main.get("terrain")
	var controller: Node = main.get("gameplay").get("controller")
	controller.set_process(false)
	await _settle(terrain, 40)
	_save("start.png")

	# A short line leaving the first town towards the second.
	var towns := sim.town_positions()
	var a := towns[0]
	var dir := (towns[1] - towns[0]).normalized()
	var side := Vector2(-dir.y, dir.x)
	var pts: Array[Vector2] = []
	for i in 6:
		pts.append(a + dir * (350.0 + i * 450.0) + side * sin(i * 1.3) * 120.0)
	controller.set_tool(Tools.Tool.TRACK)
	for p in pts:
		_click(controller, p)
	controller.cancel()
	controller.set_tool(Tools.Tool.STATION)
	_click(controller, pts[0])
	_click(controller, pts[pts.size() - 1])
	controller.set_tool(Tools.Tool.TRAIN)
	_click(controller, pts[0].lerp(pts[1], 0.5))
	controller.set_tool(Tools.Tool.ROUTE)
	_click(controller, pts[0].lerp(pts[1], 0.5))
	_click(controller, pts[pts.size() - 1])
	_click(controller, pts[0])
	controller.confirm_route()
	controller.set_tool(Tools.Tool.NONE)
	for i in 900:
		sim.step()

	# Close up on the train.
	var train: Dictionary = sim.trains()[0]
	var tp := Vector2(train["x"], train["y"])
	camera.call("jump_to", Vector3(tp.x, 0.0, tp.y), 0.9, 0.5, 160.0)
	await _settle(terrain, 30)
	_save("line_close.png")

	camera.call("jump_to", Vector3(pts[2].x, 0.0, pts[2].y), 0.4, 0.95, 6500.0)
	await _settle(terrain, 40)
	_save("overview.png")

	# The highest hill near the start, from a low angle.
	var n := 48
	var step := 250.0
	var h := sim.terrain_heights(a.x - n * step * 0.5, a.y - n * step * 0.5, step, n, n)
	var best := 0
	for i in h.size():
		if h[i] > h[best]:
			best = i
	var hill := Vector2(a.x - n * step * 0.5 + (best % n) * step, a.y - n * step * 0.5 + (best / n) * step)
	# Look from the town's side towards the hill, low over the ground.
	var to_hill := (hill - a).normalized()
	camera.call("jump_to", Vector3(hill.x, 0.0, hill.y), atan2(-to_hill.x, -to_hill.y), 0.27, 3000.0)
	await _settle(terrain, 40)
	_save("hills.png")
	quit(0)


func _settle(terrain: Node, frames: int) -> void:
	for i in frames:
		terrain.call("build_all_now")
		await process_frame


func _click(controller: Node, p: Vector2) -> void:
	controller.set("_ground", p)
	controller.set("_has_ground", true)
	controller.call("_click")


func _save(file: String) -> void:
	var img := root.get_viewport().get_texture().get_image()
	var path := _out_dir.path_join(file)
	img.save_png(path)
	print("saved ", path)
