extends SceneTree
## Town layout and rendering: the layout is deterministic, the number of
## buildings grows with the population, nothing is built on the station plot
## or the streets, and the game scene loads with every town drawn.
##
##   godot --headless --path client --script res://tests/towns.gd

const Layout := preload("res://world/towns_layout.gd")
const Builder := preload("res://world/towns_mesh.gd")

var _failed := false


func _initialize() -> void:
	_check_layouts()
	_check_game_scene.call_deferred()


func _fail(msg: String) -> void:
	push_error("TOWNS FAIL: " + msg)
	_failed = true


func _check_layouts() -> void:
	var c := Vector2(1230.0, -870.0)
	var t0 := Time.get_ticks_msec()
	var a := Layout.generate(c, "Hradek", 2400)
	var gen_ms := Time.get_ticks_msec() - t0
	var b := Layout.generate(c, "Hradek", 2400)
	if var_to_str(a) != var_to_str(b):
		_fail("layout is not deterministic")
	var other := Layout.generate(c, "Lhota", 2400)
	if var_to_str(a) == var_to_str(other):
		_fail("different names give the same layout")

	var counts := {}
	for pop: int in [500, 1500, 3000, 5000]:
		var total := 0
		for k in 4:
			var l := Layout.generate(Vector2(k * 3000.0, 500.0), "Town%d" % k, pop)
			for bd: Dictionary in l["buildings"]:
				if not bd.has("wing") and bd["kind"] != Layout.Kind.CHURCH:
					total += 1
			_check_clear(l, "Town%d/%d" % [k, pop])
		counts[pop] = total / 4
	print("towns: mean buildings by population ", counts, ", layout 2400 in ", gen_ms, " ms")
	if counts[500] < 25 or counts[500] > 70:
		_fail("a village of 500 should have about 40 houses, got %d" % counts[500])
	if not (counts[500] < counts[1500] and counts[1500] < counts[3000] and counts[3000] < counts[5000]):
		_fail("building count does not grow with population: %s" % counts)
	if counts[5000] < counts[500] * 4:
		_fail("a town of 5000 should be much bigger than a village: %s" % counts)

	var big := Layout.generate(c, "Hradek", 5000)
	var tall := 0
	var churches := 0
	for bd: Dictionary in big["buildings"]:
		if bd["kind"] == Layout.Kind.APARTMENT and int(bd["floors"]) >= 3:
			tall += 1
		if bd["kind"] == Layout.Kind.CHURCH:
			churches += 1
	if tall < 10:
		_fail("a town of 5000 should have 3-4 storey blocks, got %d" % tall)
	if churches != 2:
		_fail("expected a church (nave and tower), got %d parts" % churches)
	if (big["fields"] as Array).size() < 20:
		_fail("expected a ring of fields, got %d" % (big["fields"] as Array).size())

	t0 = Time.get_ticks_msec()
	var mesh := Builder.build(big, null)
	print("towns: mesh for 5000 in ", Time.get_ticks_msec() - t0, " ms, ",
			mesh.buildings.vertex_count() + mesh.details.vertex_count(), " building vertices")
	if mesh.buildings.vertex_count() == 0 or mesh.cluster.vertex_count() == 0 or mesh.flat.vertex_count() == 0:
		_fail("empty town mesh")


## No building on the station plot or on a street centreline.
func _check_clear(l: Dictionary, label: String) -> void:
	var plot: Dictionary = l["station_plot"]
	for full: Dictionary in l["buildings"]:
		# Neighbours in a row may touch; allow a few centimetres of slack.
		var bd := full.duplicate()
		bd["size"] = (full["size"] as Vector2) - Vector2(0.6, 0.6)
		if Layout._overlap(bd, plot):
			_fail("%s: building on the station plot" % label)
			return
		for s: Dictionary in l["streets"]:
			var pts: PackedVector2Array = s["points"]
			for i in pts.size() - 1:
				if Layout._segment_rect_distance(pts[i], pts[i + 1], bd) < 0.5:
					_fail("%s: building on a street" % label)
					return


func _check_game_scene() -> void:
	var session := root.get_node_or_null("Session")
	if session == null:
		_fail("no Session autoload")
		_finish()
		return
	session.set("change_scenes", false)
	var t0 := Time.get_ticks_msec()
	session.call("start_local", 7, 8)
	var game: Node = load("res://game/game.tscn").instantiate()
	root.add_child(game)
	print("towns: game scene with 8 towns ready in ", Time.get_ticks_msec() - t0, " ms")
	await process_frame
	var sim: SimWorld = session.get("world")
	var towns: Node = game.get("labels").get("towns")
	var expected := sim.town_positions().size()
	if expected < 3 or towns.call("town_count") != expected:
		_fail("game scene draws %s towns, the world has %d" % [towns.call("town_count"), expected])
	for i in expected:
		var node: Node3D = towns.call("town_node", i)
		for part in ["Ground", "Buildings", "Details", "Cluster"]:
			var inst := node.get_node_or_null(part) as MeshInstance3D
			if inst == null or inst.mesh == null or inst.mesh.get_surface_count() == 0:
				_fail("town %d has no %s mesh" % [i, part])
		var mat := (node.get_node("Buildings") as MeshInstance3D).mesh.surface_get_material(0)
		if not mat.resource_name.begins_with("M_town_"):
			_fail("town materials should be named M_town_*, got %s" % mat.resource_name)
	game.queue_free()
	await process_frame
	_finish()


func _finish() -> void:
	if _failed:
		quit(1)
	else:
		print("TOWNS OK")
		quit(0)
