extends SceneTree
## Headless test of the playable loop: start a local game from Session with a
## fixed seed, build a line between two towns with the build tools, run the
## sim and check that money moves and passengers are carried.
## Run: godot --headless --path client --script res://tests/game_loop.gd

const Tools := preload("res://gameplay/tools.gd")
const Loc := preload("res://game/loc.gd")
const Settings := preload("res://game/settings.gd")
const WorldGen := preload("res://game/world_gen.gd")

var failures := 0


func _initialize() -> void:
	var session: Node = root.get_node("Session")
	session.change_scenes = false

	# Menu scene builds and its dialogs exist.
	var menu: Control = (load("res://ui/main_menu.tscn") as PackedScene).instantiate()
	root.add_child(menu)
	await process_frame
	_check(menu.find_child("NewGameButton", true, false) != null, "menu has a New game button")
	_check(menu.find_child("NewGameDialog", true, false) != null, "menu has the new game dialog")
	menu.queue_free()

	# The stub join fails politely while there is no network client.
	var join_reasons: Array[String] = []
	session.join_failed.connect(func(r: String) -> void: join_reasons.append(r))
	session.join_server("127.0.0.1", 7878, "", "Test", "")
	if not ResourceLoader.exists(session.REMOTE_SCRIPT):
		_check(join_reasons == ["Online zatím není hotové"], "join stub reports failure")

	session.start_local(4242, 6)
	var sim: SimWorld = session.world
	_check(sim != null and session.mode == session.Mode.LOCAL, "session started a local game")
	var pos := sim.town_positions()
	var pops := sim.town_populations()
	_check(pos.size() == 6, "6 towns exist (%d)" % pos.size())
	for p in pops:
		_check(p >= 500 and p <= 5000, "town population in range (%d)" % p)
	_check(sim.tracks().is_empty() and sim.nodes().is_empty(), "the land starts empty")
	_check(sim.balance() == 2000000, "starting money is 2,000,000")
	_check(Loc.money(2000000) == "2 000 000 $", "money formatting")

	# Same seed, same world.
	var again := SimWorld.new()
	WorldGen.generate(again, 4242, 6)
	_check(again.town_positions() == pos and again.town_names() == sim.town_names(),
			"world generation is deterministic")
	var min_d := 1e9
	for i in pos.size():
		for j in range(i + 1, pos.size()):
			min_d = minf(min_d, pos[i].distance_to(pos[j]))
	_check(min_d >= 1000.0, "towns are spread apart (%.0f m)" % min_d)

	# Pause and speed control.
	session.set_speed(0)
	var tick0 := sim.tick()
	session._process(1.0)
	_check(sim.tick() == tick0, "paused session does not step")
	session.set_speed(4)
	session._process(0.5)
	_check(sim.tick() == tick0 + 20, "4x for 0.5 s is 20 ticks (%d)" % (sim.tick() - tick0))
	session.set_speed(1)

	# Game scene on the session world; build a line between the closest towns.
	var game: Node = (load("res://game/game.tscn") as PackedScene).instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	_check(game.get("sim") == sim, "game scene uses the session world")
	var controller: Node = game.get("gameplay").get("controller")
	controller.set_process(false)
	controller.set_process_unhandled_input(false)

	var a := 0
	var b := 1
	var best := 1e9
	for i in pos.size():
		for j in range(i + 1, pos.size()):
			if pos[i].distance_to(pos[j]) < best:
				best = pos[i].distance_to(pos[j])
				a = i
				b = j
	var pa := pos[a]
	var pb := pos[b]
	controller.set_tool(Tools.Tool.TRACK)
	_click(controller, pa)
	_click(controller, pb)
	controller.cancel()
	_check(sim.tracks().size() == 1, "track built between two towns")
	controller.set_tool(Tools.Tool.STATION)
	_click(controller, pa)
	_click(controller, pb)
	controller.set_tool(Tools.Tool.TRAIN)
	_click(controller, (pa + pb) * 0.5)
	_check(sim.trains().size() == 1, "train placed")
	controller.set_tool(Tools.Tool.ROUTE)
	_click(controller, pa) # the train stands at the start of its track
	_check(controller.get("selected_train") >= 0, "route tool selected the train")
	_click(controller, pb)
	_click(controller, pa)
	controller.confirm_route()
	var after_build := sim.balance()
	_check(after_build < 2000000, "building cost money (%d left)" % after_build)

	var max_load := 0
	var max_waiting := 0
	var max_balance := after_build
	for i in 60000:
		session.advance_ticks(1)
		if i % 20 == 0:
			for t in sim.trains():
				max_load = maxi(max_load, sim.train_load(t["id"]))
			for n in sim.nodes():
				if n["station"]:
					max_waiting = maxi(max_waiting, sim.station_waiting(n["id"]))
			max_balance = maxi(max_balance, sim.balance())
			if max_load > 0 and max_balance > after_build + 1000:
				break
	game.get("labels").refresh()
	_check(max_waiting > 0, "passengers waited at a station (%d)" % max_waiting)
	_check(max_load > 0, "a train carried passengers (%d)" % max_load)
	_check(max_balance > after_build, "balance rose from fares (%d -> %d)" % [after_build, max_balance])
	_check(sim.date_string().length() == 10, "date string " + sim.date_string())

	# Failing for lack of money is reported by the binding.
	var errors := sim.error_count()
	var far := sim.build_node(pa.x + 60000.0, pa.y)
	var track := sim.build_track(far, sim.nearest_node(pa.x, pa.y, 50.0))
	_check(track < 0 and sim.error_count() == errors + 1 and sim.last_error_is_funds(),
			"unaffordable track reports lack of funds (%s)" % sim.last_error())

	# Settings persist to a config file.
	Settings.master_volume = 0.35
	Settings.language = "en"
	_check(Settings.save_to_disk("user://test_settings.cfg") == OK, "settings saved")
	var cfg := ConfigFile.new()
	cfg.load("user://test_settings.cfg")
	_check(is_equal_approx(float(cfg.get_value("audio", "master_volume")), 0.35)
			and cfg.get_value("ui", "language") == "en", "settings file has the values")
	Settings.language = "cs"

	print("GAME LOOP %s (%d failures)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _click(controller: Node, p: Vector2) -> void:
	controller.set("_ground", p)
	controller.set("_has_ground", true)
	controller.call("_click")


func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		failures += 1
