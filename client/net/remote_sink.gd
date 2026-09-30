extends "res://gameplay/command_sink.gd"
## Command sink for an online game: submits commands through a NetClient
## and calls each `done` when its `command_result` event arrives. Results
## of successful commands arrive only once the world view shows them, so
## the ids they carry can be used right away. RemoteSession feeds it the
## events from NetClient.poll().

var net: NetClient
var _callbacks: Dictionary = {} ## seq -> Callable


func _init(p_net: NetClient) -> void:
	super(p_net.world())
	net = p_net


func is_remote() -> bool:
	return true


func build_node(x: float, y: float, done: Callable) -> void:
	_expect(net.submit_build_node(x, y), done)


func build_track(a: int, b: int, done: Callable) -> void:
	_expect(net.submit_build_track(a, b), done)


func build_station(node: int, done: Callable) -> void:
	_expect(net.submit_build_station(node), done)


func spawn_train(track: int, done: Callable) -> void:
	_expect(net.submit_spawn_train(track), done)


func set_route(train: int, stops: PackedInt64Array, done: Callable) -> void:
	_expect(net.submit_set_route(train, stops), done)


func remove_train(train: int, done: Callable) -> void:
	_expect(net.submit_remove_train(train), done)


## Commands sent but not answered yet.
func pending_count() -> int:
	return _callbacks.size()


## Handles one event from NetClient.poll().
func handle_event(ev: Dictionary) -> void:
	match ev["type"]:
		"command_result":
			var seq: int = ev["seq"]
			if not _callbacks.has(seq):
				return
			var done: Callable = _callbacks[seq]
			_callbacks.erase(seq)
			if done.is_valid(): # the tool that asked may be gone
				var ok: bool = ev["ok"]
				var id: int = ev["id"]
				var error: String = ev["error"]
				done.call(ok, id, error)
		"world_changed":
			world_changed.emit()


## Forgets all callbacks, e.g. after leaving (NetClient stops reporting).
func clear() -> void:
	_callbacks.clear()


func _expect(seq: int, done: Callable) -> void:
	if seq < 0:
		done.call(false, -1, "not connected")
	else:
		_callbacks[seq] = done
