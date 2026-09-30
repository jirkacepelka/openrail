extends SceneTree
## Headless test of online play through the real UI path: main menu, join
## dialog, Session, the game scene on the remote world, the build tools,
## leaving back to the menu, and a server shutdown during a game bringing
## the player back to the menu with the reason. Uses a local dedicated
## server (see tests/test_server.gd).
## Run: godot --headless --path client --script res://tests/online_game.gd

const Tools := preload("res://gameplay/tools.gd")
const TestServer := preload("res://tests/test_server.gd")

const PASSWORD := "online"
const TIMEOUT_MS := 30000
const MENU_SCENE := "res://ui/main_menu.tscn"
const GAME_SCENE := "res://game/game.tscn"

var failures := 0
var server: TestServer
var session: Node
var controller: Node


func _initialize() -> void:
	session = root.get_node("Session")
	await _run()
	if session.remote != null:
		session.leave_to_menu()
	if server != null:
		server.stop()
	print("ONLINE GAME %s (%d failures)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _run() -> void:
	server = TestServer.new()
	if not _check(await server.start(self, PASSWORD), "server started (%s)" % server.error):
		return

	# Main menu -> join dialog, filled in and confirmed like a player would.
	change_scene_to_file(MENU_SCENE)
	if not _check(await _wait_scene(MENU_SCENE), "main menu shown"):
		return
	var menu := current_scene
	var fields: Dictionary = menu.get("_join_fields")
	(fields["address"] as LineEdit).text = "127.0.0.1"
	(fields["port"] as SpinBox).value = server.port
	(fields["password"] as LineEdit).text = PASSWORD
	(fields["name"] as LineEdit).text = "tester"
	(fields["fingerprint"] as LineEdit).text = server.fingerprint
	var dialog := menu.find_child("JoinDialog", true, false) as ConfirmationDialog
	if not _check(dialog != null, "menu has the join dialog"):
		return
	var statuses: Array[String] = []
	session.status_changed.connect(func(t: String) -> void: statuses.append(t))
	dialog.confirmed.emit()

	# Joined: the game scene shows the server's world.
	if not _check(await _wait_scene(GAME_SCENE), "game scene loaded after joining (%s)"
			% ", ".join(statuses)):
		return
	await process_frame
	var game := current_scene
	var sim: SimWorld = game.get("sim")
	_check(session.is_remote() and session.remote != null, "session is online")
	_check(sim != null and sim == session.remote.world and sim.is_remote(),
			"game scene shows the remote world view")
	_check(sim.player_id() == session.remote.player_id and sim.player_id() > 0,
			"the view is our company (player %d)" % sim.player_id())
	var speed_button := game.find_child("Speed1", true, false) as Button
	_check(speed_button != null and not speed_button.visible, "speed buttons are hidden online")
	var tick0 := sim.tick()
	await _wait(func() -> bool: return sim.tick() > tick0 + 5)
	_check(sim.tick() > tick0, "the world advances from the server (tick %d -> %d)"
			% [tick0, sim.tick()])

	# Build a line with the tools; commands go to the server.
	controller = game.get("gameplay").get("controller")
	controller.set_process(false)
	controller.set_process_unhandled_input(false)
	var balance0 := sim.balance()
	controller.set_tool(Tools.Tool.TRACK)
	_click(Vector2(5000, 5000))
	_click(Vector2(9000, 5000))
	controller.cancel()
	_check(await _wait(func() -> bool: return sim.tracks().size() == 1), "track built online")
	await process_frame
	var track_mesh: MeshInstance3D = game.get("track_mesh")
	_check(track_mesh != null and track_mesh.mesh.get_surface_count() == 1,
			"the game scene redrew the network")
	controller.set_tool(Tools.Tool.STATION)
	_click(Vector2(5000, 5000))
	_click(Vector2(9000, 5000))
	_check(await _wait(func() -> bool: return _stations(sim) == 2), "two stations built online")
	controller.set_tool(Tools.Tool.TRAIN)
	_click(Vector2(7000, 5000))
	_check(await _wait(func() -> bool: return sim.trains().size() == 1), "train placed online")
	controller.set_tool(Tools.Tool.ROUTE)
	var train: Dictionary = sim.trains()[0]
	_click(Vector2(train["x"], train["y"]))
	_click(Vector2(9000, 5000))
	_click(Vector2(5000, 5000))
	controller.confirm_route()
	_check(await _wait(func() -> bool: return (sim.trains()[0]["stops"] as PackedInt64Array).size() == 2),
			"route confirmed by the server")
	var x0: float = sim.trains()[0]["x"]
	_check(await _wait(func() -> bool: return float(sim.trains()[0]["x"]) > x0 + 5.0),
			"the train moves (x %.1f -> %.1f)" % [x0, float(sim.trains()[0]["x"])])
	_check(sim.balance() < balance0, "building was paid (%d -> %d)" % [balance0, sim.balance()])
	var labels: Node = game.get("labels")
	labels.call("refresh")
	var train_nodes: Dictionary = labels.get("_trains")
	_check(train_nodes.has(int(train["id"])) and train_nodes.size() == 1,
			"the train has its marker, keyed by id")

	# Leave through the HUD path back to the menu.
	session.leave_to_menu()
	_check(await _wait_scene(MENU_SCENE), "leaving returns to the main menu")
	_check(session.remote == null and session.world == null and not session.is_remote(),
			"the session is closed after leaving")
	_check(current_scene.find_child("DisconnectedDialog", true, false) == null,
			"leaving on purpose shows no disconnect message")

	# Join again, then the server shuts down: back to the menu with the reason.
	menu = current_scene
	fields = menu.get("_join_fields")
	(fields["password"] as LineEdit).text = PASSWORD
	dialog = menu.find_child("JoinDialog", true, false) as ConfirmationDialog
	dialog.confirmed.emit()
	if not _check(await _wait_scene(GAME_SCENE), "joined again from the menu"):
		return
	var reasons: Array[String] = []
	session.disconnected.connect(func(r: String) -> void: reasons.append(r))
	server.shut_down()
	_check(await _wait_scene(MENU_SCENE), "a server shutdown returns to the menu")
	_check(reasons.size() == 1, "the disconnect was reported (%s)" % ", ".join(reasons))
	await process_frame
	_check(current_scene.find_child("DisconnectedDialog", true, false) != null,
			"the menu tells the player why the game ended")
	_check(session.remote == null and not session.is_remote(), "the session is closed")


func _click(p: Vector2) -> void:
	controller.set("_ground", p)
	controller.set("_has_ground", true)
	controller.call("_click")


func _stations(sim: SimWorld) -> int:
	var n := 0
	for node in sim.nodes():
		if node["station"]:
			n += 1
	return n


## Waits (the Session autoload polls the server every frame) until `cond`.
func _wait(cond: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await process_frame
	return false


func _wait_scene(path: String) -> bool:
	return await _wait(func() -> bool:
		return current_scene != null and current_scene.scene_file_path == path)


func _check(ok: bool, what: String) -> bool:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		failures += 1
	return ok
