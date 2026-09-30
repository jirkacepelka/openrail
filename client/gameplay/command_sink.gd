extends RefCounted
## Where the build tools send their commands.
##
## This base class is the local sink: it applies every command to a local
## SimWorld at once and calls `done` before returning. The remote sink
## (res://net/remote_sink.gd) sends the same commands to a server and calls
## `done` later, once the result is visible in the world view. Callers must
## handle both, so they write the follow-up in `done` and never rely on it
## having run when the call returns.
##
## Every command takes `done: Callable(ok: bool, id: int, error: String)`.
## `id` is the node, track or train the command created, or -1. `error` may
## be empty for local rejections (SimWorld gives no reason).

## The world changed through something other than this client's own
## commands (other players, a resync). Only the remote sink emits it.
signal world_changed


## A node that exists or is being built, so the Track tool can chain
## segments before the server has confirmed their end points.
class NodeRef:
	extends RefCounted

	var id := -1 ## -1 while pending or if building it failed.
	var pos := Vector2.ZERO
	var pending := false
	var error := ""
	var _waiters: Array[Callable] = []

	## Calls `callback` once the node exists or failed (right away if it
	## already did).
	func when_ready(callback: Callable) -> void:
		if pending:
			_waiters.append(callback)
		else:
			callback.call()

	func _resolve(new_id: int, err: String) -> void:
		id = new_id
		error = err
		pending = false
		var waiters := _waiters
		_waiters = []
		for w in waiters:
			w.call()


var world: SimWorld


func _init(p_world: SimWorld = null) -> void:
	world = p_world


## `true` when commands take a round trip to a server.
func is_remote() -> bool:
	return false


func build_node(x: float, y: float, done: Callable) -> void:
	var id := world.build_node(x, y)
	done.call(id >= 0, id, "")


func build_track(a: int, b: int, done: Callable) -> void:
	var id := world.build_track(a, b)
	done.call(id >= 0, id, "")


func build_station(node: int, done: Callable) -> void:
	var ok := world.build_station(node)
	done.call(ok, -1, "")


func spawn_train(track: int, done: Callable) -> void:
	var id := world.spawn_train(track)
	done.call(id >= 0, id, "")


func set_route(train: int, stops: PackedInt64Array, done: Callable) -> void:
	var ok := world.set_route(train, stops)
	done.call(ok, -1, "")


func remove_train(train: int, done: Callable) -> void:
	# SimWorld may not bind this command yet; look it up dynamically.
	if not world.has_method("remove_train"):
		done.call(false, -1, "removing trains is not supported here")
		return
	var ok: bool = world.call("remove_train", train)
	done.call(ok, -1, "")


## The existing node `id`, or (with id -1) a new node built at `pos`.
func node_ref(id: int, pos: Vector2) -> NodeRef:
	var ref := NodeRef.new()
	ref.pos = pos
	if id >= 0:
		ref.id = id
		return ref
	ref.pending = true
	build_node(pos.x, pos.y, func(ok: bool, new_id: int, err: String) -> void:
		ref._resolve(new_id if ok else -1, err)
	)
	return ref


## Builds a track between two node refs once both exist. Fails (through
## `done`) if either could not be built.
func build_track_between(a: NodeRef, b: NodeRef, done: Callable) -> void:
	a.when_ready(func() -> void:
		b.when_ready(func() -> void:
			if a.id < 0 or b.id < 0:
				var err := a.error if a.id < 0 else b.error
				done.call(false, -1, "could not build the node" + (": " + err if err != "" else ""))
				return
			build_track(a.id, b.id, done)
		)
	)
