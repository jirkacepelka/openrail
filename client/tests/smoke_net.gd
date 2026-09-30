extends SceneTree
## Headless online smoke test: starts the dedicated server
## (target/debug/openrail-server, built with cargo if missing) on a free
## port with a throwaway config, joins it through RemoteSession with the
## certificate pinned, builds a line with the build tools through the
## remote command sink and checks that the train moves.
## Run: godot --headless --path client --script res://tests/smoke_net.gd

const Tools := preload("res://gameplay/tools.gd")
const GameplayRoot := preload("res://gameplay/gameplay_root.gd")
const RemoteSession := preload("res://net/remote_session.gd")

const PASSWORD := "smoke"
const TIMEOUT_MS := 30000

var failures := 0
var server_pid := -1
var temp_dir := ""
var session: RemoteSession
var controller: Node


func _initialize() -> void:
	await _run()
	if session != null:
		session.leave()
	if server_pid > 0:
		OS.kill(server_pid)
	_remove_temp_dir()
	print("NET SMOKE %s (%d failures)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _run() -> void:
	var repo := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var exe := repo.path_join("target/debug/openrail-server")
	if OS.get_name() == "Windows":
		exe += ".exe"
	if not FileAccess.file_exists(exe):
		print("  building openrail-server with cargo...")
		OS.execute("cargo", ["build", "-p", "openrail-server", "--manifest-path",
				repo.path_join("Cargo.toml")])
	if not _check(FileAccess.file_exists(exe), "server binary exists at %s" % exe):
		return

	var port := _free_port()
	if not _check(port > 0, "found a free port"):
		return
	temp_dir = OS.get_user_data_dir().path_join("smoke_net_%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(temp_dir)
	var cfg_path := temp_dir.path_join("server.toml")
	var cfg := FileAccess.open(cfg_path, FileAccess.WRITE)
	cfg.store_string("\n".join([
		'bind = "127.0.0.1:%d"' % port,
		'game_bind = "127.0.0.1:%d"' % port,
		"seed = 3",
		'save_path = "%s"' % temp_dir.path_join("world.bin"),
		'cert_path = "%s"' % temp_dir.path_join("cert.der"),
		'key_path = "%s"' % temp_dir.path_join("key.der"),
		'password = "%s"' % PASSWORD,
		"autosave_ticks = 100000",
		"hash_interval_ticks = 10",
	]) + "\n")
	cfg.close()
	server_pid = OS.create_process(exe, ["--config", cfg_path])
	if not _check(server_pid > 0, "server started (pid %d, port %d)" % [server_pid, port]):
		return

	# The key is written after the certificate, so once it exists the
	# certificate is complete. Then wait for the server to hold the port.
	var cert := temp_dir.path_join("cert.der")
	if not await _wait(func() -> bool: return FileAccess.file_exists(temp_dir.path_join("key.der"))):
		_check(false, "server wrote its certificate")
		return
	if not await _wait(func() -> bool: return not _udp_port_free(port)):
		_check(false, "server bound its UDP port")
		return
	var fingerprint := _sha256_hex(FileAccess.get_file_as_bytes(cert))

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


func _free_port() -> int:
	for i in 50:
		var port := randi_range(20000, 60000)
		var tcp := TCPServer.new()
		var ok := tcp.listen(port, "127.0.0.1") == OK
		tcp.stop()
		if ok and _udp_port_free(port):
			return port
	return -1


func _udp_port_free(port: int) -> bool:
	var udp := PacketPeerUDP.new()
	var ok := udp.bind(port, "127.0.0.1") == OK
	udp.close()
	return ok


func _sha256_hex(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


func _remove_temp_dir() -> void:
	if temp_dir == "" or not DirAccess.dir_exists_absolute(temp_dir):
		return
	for f in DirAccess.get_files_at(temp_dir):
		DirAccess.remove_absolute(temp_dir.path_join(f))
	DirAccess.remove_absolute(temp_dir)


func _check(ok: bool, what: String) -> bool:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		failures += 1
	return ok
