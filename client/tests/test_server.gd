extends RefCounted
## Starts a local dedicated server for the online tests: builds
## target/debug/openrail-server with cargo if it is missing, writes a
## throwaway config on a free port and waits until the server listens.
##
##     var server := TestServer.new()
##     if await server.start(tree, "password"):
##         join 127.0.0.1:server.port with server.fingerprint
##     server.stop()

const WAIT_MS := 30000

var port := -1
## SHA-256 of the server certificate (hex), for pinning.
var fingerprint := ""
var pid := -1
## Why `start` failed, or "".
var error := ""
var temp_dir := ""
var _stopping_pid := -1


## Starts the server; `true` once it listens. `tree` supplies frames to wait on.
func start(tree: SceneTree, password: String) -> bool:
	var repo := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var exe := repo.path_join("target/debug/openrail-server")
	if OS.get_name() == "Windows":
		exe += ".exe"
	if not FileAccess.file_exists(exe):
		print("  building openrail-server with cargo...")
		OS.execute("cargo", ["build", "-p", "openrail-server", "--manifest-path",
				repo.path_join("Cargo.toml")])
	if not FileAccess.file_exists(exe):
		error = "no server binary at %s" % exe
		return false

	port = _free_port()
	if port <= 0:
		error = "no free port"
		return false
	temp_dir = OS.get_user_data_dir().path_join("test_server_%d_%d" % [OS.get_process_id(), port])
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
		'password = "%s"' % password,
		"autosave_ticks = 100000",
		"hash_interval_ticks = 10",
	]) + "\n")
	cfg.close()
	pid = OS.create_process(exe, ["--config", cfg_path])
	if pid <= 0:
		error = "could not start %s" % exe
		return false

	# The key is written after the certificate, so once it exists the
	# certificate is complete. Then wait for the server to hold the port.
	var key := temp_dir.path_join("key.der")
	if not await _wait(tree, func() -> bool: return FileAccess.file_exists(key)):
		error = "server wrote no certificate"
		return false
	if not await _wait(tree, func() -> bool: return not _udp_port_free(port)):
		error = "server did not bind its UDP port"
		return false
	fingerprint = _sha256_hex(FileAccess.get_file_as_bytes(temp_dir.path_join("cert.der")))
	return true


## Asks the server to shut down cleanly (Ctrl+C: it closes every connection
## and saves). Falls back to killing it where there is no `kill` command.
func shut_down() -> void:
	if pid <= 0:
		return
	if OS.get_name() == "Windows" or OS.execute("kill", ["-INT", str(pid)]) != 0:
		OS.kill(pid)
	_stopping_pid = pid
	pid = -1


## Kills the server (if still running) and removes its files.
func stop() -> void:
	if pid > 0:
		OS.kill(pid)
		pid = -1
	# Let a server that is shutting down finish its final save first.
	var deadline := Time.get_ticks_msec() + 5000
	while _stopping_pid > 0 and OS.is_process_running(_stopping_pid) \
			and Time.get_ticks_msec() < deadline:
		OS.delay_msec(20)
	_stopping_pid = -1
	if temp_dir == "" or not DirAccess.dir_exists_absolute(temp_dir):
		return
	for f in DirAccess.get_files_at(temp_dir):
		DirAccess.remove_absolute(temp_dir.path_join(f))
	DirAccess.remove_absolute(temp_dir)


func _wait(tree: SceneTree, cond: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await tree.process_frame
	return false


static func _free_port() -> int:
	for i in 50:
		var p := randi_range(20000, 60000)
		var tcp := TCPServer.new()
		var ok := tcp.listen(p, "127.0.0.1") == OK
		tcp.stop()
		if ok and _udp_port_free(p):
			return p
	return -1


static func _udp_port_free(p: int) -> bool:
	var udp := PacketPeerUDP.new()
	var ok := udp.bind(p, "127.0.0.1") == OK
	udp.close()
	return ok


static func _sha256_hex(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()
