extends RefCounted
## One visit to a dedicated server: joins it, keeps the lockstep world
## running and hands the gameplay layer what it needs.
##
## Usage (from the Session autoload or any node):
##
##     var remote := RemoteSession.new()
##     remote.joined.connect(_on_joined)
##     remote.failed.connect(_on_failed)
##     remote.join("example.org", 7878, "", "ann", "ab12...")
##     # every frame (in _process):
##     remote.poll(delta)
##     # once joined: render and pick from `remote.world`, and build with
##     # gameplay_root.setup(remote.world, camera, remote.sink)
##
## Nothing here blocks: the connection runs on a background thread inside
## NetClient and `poll` only handles what already arrived.

const RemoteSink := preload("res://net/remote_sink.gd")

## Confirmed ticks simulated per poll at most. The server runs 10 ticks a
## second; the headroom lets a client that fell behind catch up quickly.
const MAX_TICKS_PER_POLL := 50

## Connection progress for the UI ("Connecting...", "Playing as ...").
signal status_changed(text: String)
## Joined; `world`, `sink` and `player_id` are ready to use.
signal joined
## Could not join (unreachable, certificate mismatch, refused, timed out).
signal failed(reason: String)
## Lost the game after joining (kicked, server gone, network down). The
## last world stays visible in `world`.
signal disconnected(reason: String)
## Nodes, tracks, stations, trains or routes changed (anyone's).
signal world_changed
signal player_joined(id: int, name: String)
signal player_left(id: int)
signal chat_received(player_id: int, text: String)
## The local world diverged from the server's; it resyncs by itself.
signal desynced(tick: int)
signal resynced(tick: int)

var net: NetClient
## Read-only SimWorld view of the confirmed world (same queries as a local
## SimWorld; `step()` does nothing, the world advances in `poll`).
var world: SimWorld
## Command sink for the build tools (see res://gameplay/command_sink.gd).
var sink: RemoteSink
## Our player id once joined, else -1.
var player_id := -1
var status := ""


func _init() -> void:
	net = NetClient.new()
	world = net.world()
	sink = RemoteSink.new(net)


## Starts joining. `fingerprint` is the server certificate's SHA-256 (64
## hex digits, colons allowed) that the server prints at start and shows
## at /status; "" skips the check (development only). Leaves any earlier
## game first. Emits `failed` right away on invalid input.
func join(address: String, port: int, password: String, player_name: String, fingerprint: String) -> void:
	sink.clear()
	player_id = -1
	var err := net.connect_to_server(address.strip_edges(), port, password, player_name.strip_edges(),
			fingerprint.strip_edges())
	if err != "":
		_set_status("Could not join: " + err)
		failed.emit(err)
		return
	_set_status(net.status_text())


## Call every frame. Handles what arrived and advances the world.
func poll(_delta: float = 0.0) -> void:
	for ev: Dictionary in net.poll(MAX_TICKS_PER_POLL):
		sink.handle_event(ev)
		match ev["type"]:
			"joined":
				player_id = ev["player_id"]
				_set_status(net.status_text())
				joined.emit()
			"failed":
				_set_status(net.status_text())
				failed.emit(String(ev["reason"]))
			"disconnected":
				_set_status(net.status_text())
				disconnected.emit(String(ev["reason"]))
			"world_changed":
				world_changed.emit()
			"player_joined":
				player_joined.emit(int(ev["player_id"]), String(ev["name"]))
			"player_left":
				player_left.emit(int(ev["player_id"]))
			"chat":
				chat_received.emit(int(ev["player_id"]), String(ev["text"]))
			"desync":
				desynced.emit(int(ev["tick"]))
			"resynced":
				resynced.emit(int(ev["tick"]))
	var s := net.status_text()
	if s != status:
		_set_status(s)


## Leaves the server. Commands in flight are dropped without callbacks.
func leave() -> void:
	net.leave()
	sink.clear()
	_set_status(net.status_text())


## "idle", "connecting", "joining", "playing" or "closed".
func state() -> String:
	return net.state()


func is_playing() -> bool:
	return net.is_playing()


## Everyone who has played on the server as {id, name, connected}.
func players() -> Array[Dictionary]:
	return net.players()


func send_chat(text: String) -> void:
	net.send_chat(text)


func _set_status(text: String) -> void:
	status = text
	status_changed.emit(text)
