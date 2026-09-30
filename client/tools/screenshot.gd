extends SceneTree
## Renders a scene for a few frames and saves a PNG, for checking the look
## without the editor (also works in CI under xvfb with a software Vulkan).
##
##   godot --path client --script res://tools/screenshot.gd -- \
##       --scene res://main.tscn --out /tmp/shot.png --frames 60 \
##       --look-from 1500,900,2600 --look-at 1500,0,1000
##
## --look-from / --look-at are optional and move the active camera.

var _frames_left := 60
var _out := "user://screenshot.png"
var _args := {}


func _initialize() -> void:
	var args := _parse(OS.get_cmdline_user_args())
	_frames_left = int(args.get("frames", "60"))
	_out = args.get("out", _out)
	var scene: PackedScene = load(args.get("scene", "res://main.tscn"))
	var inst := scene.instantiate()
	root.add_child(inst)
	_args = args


func _move_camera() -> void:
	if not _args.has("look-from"):
		return
	var cam := root.get_camera_3d()
	if cam != null:
		# An RTS camera script would move it straight back; hold it still.
		cam.set_process(false)
		var from := _vec3(_args["look-from"])
		var at := _vec3(_args.get("look-at", "0,0,0"))
		cam.look_at_from_position(from, at)


func _process(_delta: float) -> bool:
	# The camera only becomes current once the scene is in the tree.
	_move_camera()
	_frames_left -= 1
	if _frames_left > 0:
		return false
	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png(_out)
	if err != OK:
		push_error("screenshot: could not save %s (%d)" % [_out, err])
	else:
		print("screenshot: saved ", _out)
	return true


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
