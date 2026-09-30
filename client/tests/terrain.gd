extends SceneTree
## Headless terrain test: heights are deterministic and match everywhere
## they are used (ground helper, terrain mesh, track mesh), picking hits the
## hills, towns sit on flat dry ground and the game scene starts close to
## the first town with the camera above the ground. The remote view's
## terrain is checked in smoke_net.gd.
## Run: godot --headless --path client --script res://tests/terrain.gd

const Ground := preload("res://world/ground.gd")
const Terrain := preload("res://world/terrain.gd")
const TrackMesh := preload("res://world/track_mesh.gd")
const GroundPick := preload("res://gameplay/ground_pick.gd")
const RtsCamera := preload("res://gameplay/rts_camera.gd")
const WorldGen := preload("res://game/world_gen.gd")

var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_heights()
	_picking()
	await _meshes()
	_towns()
	await _game_scene()
	print("TERRAIN %s (%d failures)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _world(seed_value: int) -> SimWorld:
	var sim := SimWorld.new()
	sim.new_world(seed_value)
	return sim


func _heights() -> void:
	var a := _world(7)
	var b := _world(7)
	var c := _world(8)
	var grid := a.terrain_heights(-6000, -4000, 200, 40, 30)
	_check(grid.size() == 1200, "grid has nx * ny heights")
	_check(grid == b.terrain_heights(-6000, -4000, 200, 40, 30), "same seed, same heights")
	_check(grid != c.terrain_heights(-6000, -4000, 200, 40, 30), "other seed, other heights")
	_check(is_equal_approx(grid[3 * 40 + 5], a.terrain_height(-6000 + 5 * 200, -4000 + 3 * 200)),
			"grid index iy * nx + ix is (x0 + ix * step, y0 + iy * step)")
	var at := a.terrain_heights_at(PackedVector2Array([Vector2(-5800, -3800), Vector2(1234, 567)]))
	_check(is_equal_approx(at[0], grid[1 * 40 + 1]) and is_equal_approx(at[1], a.terrain_height(1234, 567)),
			"terrain_heights_at matches the grid and single samples")
	var lo := INF
	var hi := -INF
	var wet := 0
	var big := a.terrain_heights(-20000, -20000, 250, 160, 160)
	for h in big:
		lo = minf(lo, h)
		hi = maxf(hi, h)
		if h < a.terrain_water_level():
			wet += 1
	_check(lo >= 0.0 and hi <= a.terrain_max_height(), "heights within 0..max (%.0f..%.0f)" % [lo, hi])
	_check(hi - lo > 100.0, "there are hills and valleys (%.0f m relief)" % (hi - lo))
	_check(wet > 0 and wet < big.size() / 4, "some water, mostly land (%d of %d)" % [wet, big.size()])
	var w := a.terrain_wetness(-6000, -4000, 200, 40, 30)
	_check(w.size() == 1200 and w[0] >= 0.0 and w[0] <= 1.0, "wetness grid in 0..1")
	_check(is_equal_approx(Ground.height_at(a, 100, 200), a.terrain_height(100, 200)),
			"Ground.height_at is the sim terrain height")
	_check(Ground.normal_at(a, 100, 200).y > 0.5, "ground normal points up")


func _picking() -> void:
	var sim := _world(1)
	var p := _hillside(sim)
	var hp := sim.terrain_height(p.x, p.y)
	_check(hp > 60.0, "found a hillside to click on (%.0f m)" % hp)
	# Straight down onto the hill.
	var hit: Variant = GroundPick.ray_terrain(sim, Vector3(p.x, 2000, p.y), Vector3.DOWN)
	_check(hit is Vector3 and absf((hit as Vector3).y - hp) < 0.05, "a vertical ray hits the ground")
	# A slanted ray, like a camera 30 degrees above the horizon, aimed at the hill.
	var target := Vector3(p.x, hp, p.y)
	var dir := Vector3(0.6, -0.5, 0.62).normalized()
	var origin := target - dir * 1500.0
	hit = GroundPick.ray_terrain(sim, origin, dir)
	_check(hit is Vector3 and (hit as Vector3).distance_to(target) < 2.0,
			"a slanted ray hits the hill where it points (%s)" % str(hit))
	var flat: Variant = Plane(Vector3.UP, 0.0).intersects_ray(origin, dir)
	_check(flat is Vector3 and (flat as Vector3).distance_to(target) > 50.0,
			"the flat plane would have missed it")
	_check(GroundPick.ray_terrain(sim, origin, Vector3(0.3, 0.2, 0.93).normalized()) == null,
			"a ray into the sky misses")
	# Through a camera, at the centre of the screen.
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.look_at_from_position(origin, target)
	var size := root.get_visible_rect().size
	hit = GroundPick.pick(cam, size * 0.5, sim)
	_check(hit is Vector3 and (hit as Vector3).distance_to(target) < 3.0, "camera pick hits the hill")
	cam.queue_free()


## A point on a hillside (high and sloped) near the map centre.
func _hillside(sim: SimWorld) -> Vector2:
	var n := 60
	var step := 200.0
	var h := sim.terrain_heights(-6000, -6000, step, n, n)
	var best := Vector2.ZERO
	var best_score := -INF
	for iy in range(1, n - 1):
		for ix in range(1, n - 1):
			var i := iy * n + ix
			var slope := absf(h[i + 1] - h[i - 1]) + absf(h[i + n] - h[i - n])
			var score := h[i] + slope * 2.0
			if score > best_score:
				best_score = score
				best = Vector2(-6000 + ix * step, -6000 + iy * step)
	return best


func _meshes() -> void:
	var sim := _world(1)
	var scene := Node3D.new()
	root.add_child(scene)
	var cam := RtsCamera.new()
	scene.add_child(cam)
	cam.sim = sim
	cam.jump_to(Vector3.ZERO, 0.5, 0.7, 600.0)
	var terrain := Terrain.new()
	scene.add_child(terrain)
	terrain.setup(sim, cam)
	terrain.build_all_now()
	_check(terrain.chunk_count() > 30, "terrain chunks around the camera (%d)" % terrain.chunk_count())

	var t0 := Time.get_ticks_usec()
	terrain.build_chunk_mesh(Vector2(0, 0), 512.0, 16.0)
	print("  (a nearest chunk builds in %.1f ms)" % ((Time.get_ticks_usec() - t0) / 1000.0))
	var mesh := terrain.build_chunk_mesh(Vector2(-1024, 2048), 1024.0, 64.0)
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var custom: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var ok := true
	for i in [0, 17, 100, 288]: # grid vertices (17 per side at 64 m)
		var v := verts[i]
		var h := sim.terrain_height(v.x - 1024, v.z + 2048)
		ok = ok and absf(v.y - h) < 0.01 and absf(custom[i * 4] - h) < 0.01
		ok = ok and absf(colors[i].r - clampf(h / Terrain.HEIGHT_NORM, 0, 1)) < 0.01
		ok = ok and uvs[i].is_equal_approx(Vector2(v.x - 1024, v.z + 2048) / Terrain.UV_SCALE)
	_check(ok, "chunk vertices carry the sim height, COLOR, CUSTOM0 and UV")
	_check(custom.size() == verts.size() * 4, "CUSTOM0 has four floats per vertex")

	# A track across the hills.
	sim.build_node(-800, -300)
	sim.build_node(900, 400)
	sim.build_track(1, 2)
	var tracks := TrackMesh.new()
	scene.add_child(tracks)
	tracks.setup(sim)
	var bed: MeshInstance3D = tracks.get_node("Ballast")
	var sleepers: MultiMeshInstance3D = tracks.get_node("Sleepers")
	_check(bed.mesh != null and tracks.get_node("Rails").get("mesh") != null, "track has ballast and rails")
	var length := Vector2(-800, -300).distance_to(Vector2(900, 400))
	_check(absi(sleepers.multimesh.instance_count - int(length / TrackMesh.SLEEPER_SPACING)) <= 1,
			"sleepers along the whole track (%d)" % sleepers.multimesh.instance_count)
	var bed_verts: PackedVector3Array = (bed.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var worst := 0.0
	for v in bed_verts:
		worst = maxf(worst, absf(v.y - tracks.track_base(sim.terrain_height(v.x, v.z))))
	_check(not bed_verts.is_empty() and worst < 1.5,
			"the ballast bed hugs the ground (worst %.2f m)" % worst)

	# The camera stays above a hill even when pointed low at it.
	var p := _hillside(sim)
	cam.jump_to(Vector3(p.x, 0, p.y), 1.0, RtsCamera.MIN_PITCH, 60.0)
	var cp := cam.global_position
	_check(cp.y > sim.terrain_height(cp.x, cp.z) + 5.0, "camera above the ground")
	scene.queue_free()
	await process_frame


func _towns() -> void:
	var sim := SimWorld.new()
	var n := WorldGen.generate(sim, 5, 8)
	_check(n == 8, "8 towns founded")
	var good := 0
	for p in sim.town_positions():
		if WorldGen.good_site(sim, p):
			good += 1
	_check(good == n, "every town on flat, dry ground (%d of %d)" % [good, n])


func _game_scene() -> void:
	var main: Node = (load("res://main.tscn") as PackedScene).instantiate()
	var cam: Camera3D = main.get_node("Camera3D")
	cam.set("edge_pan", false) # the headless mouse sits on the window edge
	root.add_child(main)
	await process_frame
	await process_frame
	var sim: SimWorld = main.get("sim")
	var terrain: Node = main.get("terrain")
	_check(terrain != null and int(terrain.call("chunk_count")) > 0, "game scene shows the terrain")
	var art := main.get_node_or_null("ArtStyle")
	_check(art != null and not bool(art.get("add_ground")), "flat painted ground is off")
	var town := sim.town_positions()[0]
	var focus: Vector3 = cam.get("focus")
	_check(Vector2(focus.x, focus.z).distance_to(town) < 1.0, "camera starts on the first town")
	var d: float = cam.get("distance")
	_check(d >= 300.0 and d <= 600.0, "start distance %.0f m" % d)
	var cp := cam.global_position
	_check(cp.y > sim.terrain_height(cp.x, cp.z), "camera above the ground")
	main.queue_free()
	await process_frame


func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		failures += 1
