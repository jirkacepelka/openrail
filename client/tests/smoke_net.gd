extends SceneTree
## Headless online smoke test: starts the dedicated server
## (see tests/test_server.gd), joins it through RemoteSession with the
## certificate pinned, builds a line with the build tools through the
## remote command sink and checks that the train moves.
## Run: godot --headless --path client --script res://tests/smoke_net.gd

const Tools := preload("res://gameplay/tools.gd")
const GameplayRoot := preload("res://gameplay/gameplay_root.gd")
const RemoteSession := preload("res://net/remote_session.gd")
const TestServer := preload("res://tests/test_server.gd")

const PASSWORD := "smoke"
const TIMEOUT_MS := 30000

var failures := 0
var server: TestServer
var session: RemoteSession
var controller: Node


func _initialize() -> void:
	await _run()
	if session != null:
		session.leave()
	if server != null:
		server.stop()
	print("NET SMOKE %s (%d failures)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _run() -> void:
	server = TestServer.new()
	if not _check(await server.start(self, PASSWORD), "server started (%s)" % server.error):
		return
	var port := server.port
	var fingerprint := server.fingerprint

	# Join with the certificate pinned.
	session = RemoteSession.new()
	var statuses: Array[String] = []
	var fail_reason: Array[String] = []
	session.status_changed.connect(func(t: String) -> void: statuses.append(t))
	session.failed.connect(func(r: String) -> void: fail_reason.append(r))
	session.join("127.0.0.1", port, PASSWORD, "smoke", fingerprint)
	var joined := await _wait(func() -> bool: return session.is_playing() or not fail_reason.is_empty())
	if not _check(joined and session.is_playing(), "joined the server (%s)" % ", ".join(fail_reason)):
		return
	_check(session.player_id > 0, "got a player id (%d)" % session.player_id)
	_check(session.world.is_remote(), "world is a remote view")
	_check(session.world.player_id() == session.player_id, "view shows our company")
	_check(statuses.size() >= 2, "status went through %s" % str(statuses))

	# The gameplay layer on the remote world, as a game scene would set it up.
	var scene := Node3D.new()
	root.add_child(scene)
	var camera := Camera3D.new()
	scene.add_child(camera)
	var gameplay: GameplayRoot = GameplayRoot.new()
	scene.add_child(gameplay)
	gameplay.setup(session.world, camera, session.sink)
	controller = gameplay.controller
	controller.set_process(false)
	controller.set_process_unhandled_input(false)
	var sim := session.world
	var balance_start := sim.balance()

	# One chain of two tracks; the second segment is asked for before the
	# first one's end node exists.
	controller.set_tool(Tools.Tool.TRACK)
	_click(5000, 5000)
	_click(7000, 5000)
	_click(9000, 5000)
	controller.cancel()
	_check(sim.nodes().size() == 0, "nothing is built before the server confirms")
	_check(await _wait(func() -> bool: return sim.nodes().size() == 3 and sim.tracks().size() == 2),
			"track tool built 3 nodes and 2 tracks online (%d, %d)" % [sim.nodes().size(), sim.tracks().size()])

	controller.set_tool(Tools.Tool.STATION)
	_click(5000, 5000)
	_click(9000, 5000)
	_check(await _wait(func() -> bool: return _station_count(sim) == 2), "station tool built 2 stations")

	controller.set_tool(Tools.Tool.TRAIN)
	_click(6000, 5000)
	_check(await _wait(func() -> bool: return sim.trains().size() == 1), "train tool placed a train")

	controller.set_tool(Tools.Tool.ROUTE)
	# Unrouted trains shuttle, so click where it is now.
	var train: Dictionary = sim.trains()[0]
	_click(train["x"], train["y"]) # selects the train
	_check(controller.get("selected_train") >= 0, "route tool selected the train")
	_click(9000, 5000)
	_click(5000, 5000)
	_check(controller.can_confirm_route(), "route has stops to confirm")
	controller.confirm_route()
	_check(await _wait(func() -> bool: return _routed(sim)), "route confirmed by the server")

	var start_x: float = sim.trains()[0]["x"]
	var tick := sim.tick()
	_check(await _wait(func() -> bool: return float(sim.trains()[0]["x"]) > start_x + 5.0),
			"routed train moves (x %.1f -> %.1f)" % [start_x, float(sim.trains()[0]["x"])])
	_check(sim.tick() > tick, "world view advances (tick %d -> %d)" % [tick, sim.tick()])
	_check(sim.balance() < balance_start, "building was paid from our company (%d -> %d)"
			% [balance_start, sim.balance()])
	_check(session.sink.pending_count() == 0, "every command got its result")
	# A refused command reports back too.
	var refused: Array[bool] = []
	session.sink.build_track(1, 1, func(ok: bool, _id: int, _err: String) -> void: refused.append(ok))
	_check(await _wait(func() -> bool: return not refused.is_empty()) and not refused[0],
			"a bad command is rejected by the server")
	var frozen := sim.tick()
	sim.step()
	_check(sim.tick() == frozen and sim.build_node(0, 0) < 0, "the remote view is read-only")


func _click(x: float, y: float) -> void:
	controller.set("_ground", Vector2(x, y))
	controller.set("_has_ground", true)
	controller.call("_click")


func _station_count(sim: SimWorld) -> int:
	var n := 0
	for node in sim.nodes():
		if node["station"]:
			n += 1
	return n


func _routed(sim: SimWorld) -> bool:
	var trains := sim.trains()
	if trains.is_empty():
		return false
	var stops: PackedInt64Array = trains[0]["stops"]
	return stops.size() == 2


## Polls the session every frame until `cond` holds or the time is up.
func _wait(cond: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		if session != null:
			session.poll(1.0 / 60.0)
		if cond.call():
			return true
		await process_frame
	return false


func _check(ok: bool, what: String) -> bool:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		failures += 1
	return ok
