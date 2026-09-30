extends SceneTree
## Screenshots of one town from given distances, for checking how towns look
## (the game camera is left alone; this script parks it).
##
##   xvfb-run -a -s "-screen 0 1920x1080x24" godot --path client \
##       --script res://tools/towns_screenshot.gd -- --out /tmp/town \
##       --town -1 --views 400:40:30,2000:40:30
##
## --town: town index, -1 = the biggest. --views: distance (m) : pitch (deg)
## : yaw (deg) per shot, saved as <out>_<n>.png. --seed / --towns: the world.

const Ground := preload("res://world/ground.gd")

var _args := {}
var _views: Array[Vector3] = []
var _shot := 0
var _wait := 0
var _cam: Camera3D
var _focus := Vector3.ZERO


func _initialize() -> void:
	_args = _parse(OS.get_cmdline_user_args())
	for v in String(_args.get("views", "400:40:30,2000:40:30")).split(","):
		var p := v.split(":")
		_views.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
	var session := root.get_node("Session")
	session.set("change_scenes", false)
	session.call("start_local", int(_args.get("seed", "1")), int(_args.get("towns", "6")))
	var game: Node = load("res://game/game.tscn").instantiate()
	root.add_child(game)
	var sim: SimWorld = session.get("world")
	var idx := int(_args.get("town", "-1"))
	var pops := sim.town_populations()
	if idx < 0: # -1 = the biggest town, -2 = the smallest
		var biggest := idx == -1
		idx = 0
		for i in pops.size():
			if (pops[i] > pops[idx]) == biggest and pops[i] != pops[idx]:
				idx = i
	var p := sim.town_positions()[idx]
	_focus = Vector3(p.x, Ground.height_at(sim, p.x, p.y), p.y) + _vec3(_args.get("offset", "0,0,0"))
	print("towns_screenshot: town ", idx, " ", sim.town_names()[idx], " pop ", pops[idx], " at ", p)
	# A camera of our own: the game's RTS camera keeps steering its own.
	(game.get_node("Camera3D") as Camera3D).set_process(false)
	_cam = Camera3D.new()
	_cam.name = "ShotCamera"
	game.add_child(_cam)
	_cam.make_current()
	_wait = int(_args.get("frames", "40"))


func _process(_delta: float) -> bool:
	var v := _views[_shot]
	var yaw := deg_to_rad(v.z)
	var pitch := deg_to_rad(v.y)
	var off := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * v.x
	_cam.far = 20000.0
	_cam.near = 0.5 # the Compatibility renderer here has no reverse-Z depth
	_cam.look_at_from_position(_focus + off, _focus)
	_wait -= 1
	if _wait > 0:
		return false
	var out := "%s_%d.png" % [_args.get("out", "/tmp/town"), _shot]
	root.get_viewport().get_texture().get_image().save_png(out)
	print("towns_screenshot: saved ", out)
	_shot += 1
	_wait = 12
	return _shot >= _views.size()


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


func _vec3(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2]))
