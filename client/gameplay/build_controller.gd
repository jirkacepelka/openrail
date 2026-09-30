extends Node
## Build tools controller: Track, Station, Train and Route tools plus hover
## picking. All world changes go through a command sink (local: applied at
## once; online: sent to the server, results arrive later), reads go to the
## SimWorld (local, or the read-only view of an online game). This node only
## keeps a cached copy of nodes / tracks for picking and drawing.

const Tools := preload("res://gameplay/tools.gd")
const GroundPick := preload("res://gameplay/ground_pick.gd")
const RtsCamera := preload("res://gameplay/rts_camera.gd")
const BuildOverlay := preload("res://gameplay/build_overlay.gd")
const CommandSink := preload("res://gameplay/command_sink.gd")
const Loc := preload("res://game/loc.gd")

## Emitted after nodes or tracks changed (rebuild the network rendering).
signal network_changed
## Emitted after trains or their routes changed.
signal trains_changed
signal tool_changed(tool: int)
signal hint_changed(text: String)
## Route draft (selected train / chosen stops) changed.
signal draft_changed
signal hover_changed(node_id: int)
## A build command was rejected (`error` may be empty). "not enough money"
## is the error text for missing funds, locally and online.
signal command_failed(error: String)

const MIN_TRACK_LENGTH := 20.0 ## Metres.
const COLOR_NODE := Color(0.85, 0.85, 0.85, 0.9)
const COLOR_STATION := Color(1.0, 0.85, 0.2, 1.0)
const COLOR_HOVER := Color(0.3, 0.9, 1.0, 1.0)
const COLOR_GHOST_OK := Color(0.4, 1.0, 0.4, 1.0)
const COLOR_GHOST_BAD := Color(1.0, 0.35, 0.3, 1.0)
const COLOR_ROUTE := Color(1.0, 0.55, 0.15, 1.0)

var sim: SimWorld
var sink: CommandSink
var camera: Camera3D
var overlay: BuildOverlay

var current_tool: int = Tools.Tool.NONE
var hint := ""
var hover_node := -1

# Track tool state (a "chain" starts with the first click).
var chain_active := false
var chain_node := -1 ## Existing node id, or -1 if the start is a free point.
var chain_pos := Vector2.ZERO
## End of the last segment asked for; may still be waiting for the server.
var chain_ref: CommandSink.NodeRef = null

# Route tool state.
var selected_train := -1
var route_stops: Array[int] = []

var _nodes: Dictionary = {} ## id -> Dictionary {id, x, y, station}
var _tracks: Array[Dictionary] = []
var _has_ground := false
var _ground := Vector2.ZERO


## `p_sink` defaults to a local sink applying commands to `p_sim`; pass a
## RemoteSession's sink (and its world as `p_sim`) to build online.
func setup(p_sim: SimWorld, p_camera: Camera3D, p_overlay: BuildOverlay,
		p_sink: CommandSink = null) -> void:
	sim = p_sim
	sink = p_sink if p_sink != null else CommandSink.new(p_sim)
	sink.world_changed.connect(_on_world_changed)
	camera = p_camera
	overlay = p_overlay
	if overlay != null:
		overlay.sim = sim
	refresh_cache()
	_set_hint(_default_hint())


func refresh_cache() -> void:
	_nodes.clear()
	for n in sim.nodes():
		var id: int = n["id"]
		_nodes[id] = n
	_tracks.clear()
	for t in sim.tracks():
		_tracks.append(t)


# --- Public API used by the UI -------------------------------------------


func set_tool(tool: int) -> void:
	if tool == Tools.Tool.BULLDOZE:
		return # placeholder, not implemented
	_reset_drafts()
	current_tool = tool
	tool_changed.emit(tool)
	draft_changed.emit()
	_set_hint(_default_hint())


func select_train(train_id: int) -> void:
	selected_train = train_id
	route_stops.clear()
	if current_tool != Tools.Tool.ROUTE:
		current_tool = Tools.Tool.ROUTE
		chain_active = false
		tool_changed.emit(current_tool)
	draft_changed.emit()
	_set_hint(_default_hint())


func focus_train(train_id: int) -> void:
	for t in sim.trains():
		var id: int = t["id"]
		if id == train_id and camera is RtsCamera:
			var x: float = t["x"]
			var y: float = t["y"]
			(camera as RtsCamera).focus_on(Vector3(x, 0.0, y))


func can_confirm_route() -> bool:
	return current_tool == Tools.Tool.ROUTE and selected_train >= 0 and route_stops.size() >= 2


func confirm_route() -> void:
	if not can_confirm_route():
		_set_hint(Loc.t("hint.route_incomplete"))
		return
	var stops := PackedInt64Array()
	for s in route_stops:
		stops.append(s)
	var id := selected_train
	_set_waiting_hint()
	sink.set_route(id, stops, func(ok: bool, _unused: int, err: String) -> void:
		if not ok:
			_fail(Loc.t("hint.route_rejected", [_reason(err)]), err)
			return
		if selected_train == id:
			selected_train = -1
			route_stops.clear()
			draft_changed.emit()
		trains_changed.emit()
		_set_hint(Loc.t("hint.route_set", [id]))
	)


func undo_route_stop() -> void:
	if current_tool == Tools.Tool.ROUTE and not route_stops.is_empty():
		route_stops.pop_back()
		draft_changed.emit()
		_set_hint(_default_hint())


func cancel() -> void:
	match current_tool:
		Tools.Tool.TRACK:
			if chain_active:
				chain_active = false
				chain_node = -1
				chain_ref = null
				_set_hint(_default_hint())
			else:
				set_tool(Tools.Tool.NONE)
		Tools.Tool.ROUTE:
			if not route_stops.is_empty():
				route_stops.clear()
				draft_changed.emit()
				_set_hint(_default_hint())
			elif selected_train >= 0:
				selected_train = -1
				draft_changed.emit()
				_set_hint(_default_hint())
			else:
				set_tool(Tools.Tool.NONE)
		Tools.Tool.NONE:
			pass
		_:
			set_tool(Tools.Tool.NONE)


func station_label(node_id: int) -> String:
	return Loc.t("node.station", [node_id])


func describe_node(node_id: int) -> String:
	if not _nodes.has(node_id):
		return ""
	var n: Dictionary = _nodes[node_id]
	var is_station: bool = n["station"]
	var x: float = n["x"]
	var y: float = n["y"]
	var links := 0
	for t in _tracks:
		var a: int = t["a"]
		var b: int = t["b"]
		if a == node_id or b == node_id:
			links += 1
	var lines := PackedStringArray()
	lines.append(station_label(node_id) if is_station else Loc.t("node.junction", [node_id]))
	lines.append(Loc.t("node.position", [roundi(x), roundi(y)]))
	lines.append(Loc.t("node.tracks", [links]))
	if is_station:
		var served := PackedStringArray()
		for t in sim.trains():
			var stops: PackedInt64Array = t["stops"]
			if stops.has(node_id):
				served.append(str(t["id"]))
		lines.append(Loc.t("node.trains", [", ".join(served) if not served.is_empty() else Loc.t("node.no_trains")]))
	return "\n".join(lines)


func snap_radius() -> float:
	var d := 1000.0
	if camera is RtsCamera:
		d = (camera as RtsCamera).distance
	return clampf(d * 0.03, 40.0, 400.0)


# --- Input ------------------------------------------------------------------


func _unhandled_input(event: InputEvent) -> void:
	if sim == null:
		return
	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		match key.keycode:
			KEY_ESCAPE:
				cancel()
			KEY_ENTER, KEY_KP_ENTER:
				confirm_route()
			KEY_BACKSPACE:
				undo_route_stop()
			KEY_1:
				_toggle_tool(Tools.Tool.TRACK)
			KEY_2:
				_toggle_tool(Tools.Tool.STATION)
			KEY_3:
				_toggle_tool(Tools.Tool.TRAIN)
			KEY_4:
				_toggle_tool(Tools.Tool.ROUTE)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_click()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			cancel()


func _toggle_tool(tool: int) -> void:
	set_tool(Tools.Tool.NONE if current_tool == tool else tool)


func _process(_delta: float) -> void:
	if sim == null or camera == null:
		return
	_update_ground()
	_update_hover()
	_draw_overlay()


func _update_ground() -> void:
	_has_ground = false
	var vp := camera.get_viewport()
	if vp.gui_get_hovered_control() != null:
		return
	var hit: Variant = GroundPick.pick_mouse(camera, sim)
	if hit is Vector3:
		_ground = GroundPick.to_sim(hit as Vector3)
		_has_ground = true


func _update_hover() -> void:
	var id := -1
	if _has_ground:
		id = sim.nearest_node(_ground.x, _ground.y, snap_radius())
	if id != hover_node:
		hover_node = id
		hover_changed.emit(id)


# --- Clicks -----------------------------------------------------------------


func _click() -> void:
	if not _has_ground:
		return
	match current_tool:
		Tools.Tool.TRACK:
			_click_track()
		Tools.Tool.STATION:
			_click_station()
		Tools.Tool.TRAIN:
			_click_train()
		Tools.Tool.ROUTE:
			_click_route()


## The cached node `id`; refreshes the cache once if it is missing (another
## player may have built it since the last refresh). Empty if unknown.
func _node(id: int) -> Dictionary:
	if not _nodes.has(id):
		refresh_cache()
	return _nodes.get(id, {})


func _node_pos(id: int) -> Vector2:
	var n := _node(id)
	if n.is_empty():
		return Vector2.ZERO
	var x: float = n["x"]
	var y: float = n["y"]
	return Vector2(x, y)


func _track_exists(a: int, b: int) -> bool:
	for t in _tracks:
		var ta: int = t["a"]
		var tb: int = t["b"]
		if (ta == a and tb == b) or (ta == b and tb == a):
			return true
	return false


func _click_track() -> void:
	var snapped_id := sim.nearest_node(_ground.x, _ground.y, snap_radius())
	var pos := _node_pos(snapped_id) if snapped_id >= 0 else _ground
	if not chain_active:
		chain_active = true
		chain_node = snapped_id
		chain_pos = pos
		chain_ref = null
		_set_hint(_default_hint())
		return
	var start_id := _chain_id()
	if snapped_id >= 0 and snapped_id == start_id:
		return
	if chain_pos.distance_to(pos) < MIN_TRACK_LENGTH:
		_set_hint(Loc.t("hint.track_short", [int(MIN_TRACK_LENGTH)]))
		return
	if snapped_id >= 0 and start_id >= 0 and _track_exists(start_id, snapped_id):
		_set_hint(Loc.t("hint.track_exists"))
		return
	# Online the end points may not exist yet; the sink builds the track
	# once both are confirmed. Locally all of this happens right here.
	var a := chain_ref if chain_ref != null else sink.node_ref(chain_node, chain_pos)
	var b := sink.node_ref(snapped_id, pos)
	# Chain: the end of this track is the start of the next one.
	chain_ref = b
	chain_node = b.id
	chain_pos = pos
	_set_waiting_hint()
	sink.build_track_between(a, b, _on_track_built.bind(b))


func _on_track_built(ok: bool, _track: int, err: String, end: CommandSink.NodeRef) -> void:
	refresh_cache()
	network_changed.emit()
	if chain_ref == end and end.id >= 0:
		chain_node = end.id
	if ok:
		_set_hint(_default_hint())
		return
	_fail(Loc.t("hint.track_failed", [_reason(err)]), err)
	if chain_ref == end:
		chain_active = false
		chain_node = -1
		chain_ref = null


## Id of the node the chain continues from, or -1 (free point or pending).
func _chain_id() -> int:
	return chain_ref.id if chain_ref != null else chain_node


func _click_station() -> void:
	var id := sim.nearest_node(_ground.x, _ground.y, snap_radius())
	if id < 0:
		_set_hint(Loc.t("hint.station_no_node"))
		return
	var n := _node(id)
	var is_station: bool = n.get("station", false)
	if is_station:
		_set_hint(Loc.t("hint.station_exists", [id]))
		return
	_set_waiting_hint()
	sink.build_station(id, func(ok: bool, _unused: int, err: String) -> void:
		if ok:
			refresh_cache()
			_set_hint(Loc.t("hint.station_built", [id]))
			network_changed.emit()
		else:
			_fail(Loc.t("hint.station_failed", [_reason(err)]), err)
	)


func _nearest_track(p: Vector2, max_dist: float) -> int:
	var best := -1
	var best_d := max_dist
	for t in _tracks:
		var a: int = t["a"]
		var b: int = t["b"]
		if not _nodes.has(a) or not _nodes.has(b):
			continue
		var pa := _node_pos(a)
		var pb := _node_pos(b)
		var closest := Geometry2D.get_closest_point_to_segment(p, pa, pb)
		var d := p.distance_to(closest)
		if d <= best_d:
			best_d = d
			var tid: int = t["id"]
			best = tid
	return best


func _click_train() -> void:
	var track_id := _nearest_track(_ground, snap_radius())
	if track_id < 0:
		_set_hint(Loc.t("hint.train_no_track"))
		return
	_set_waiting_hint()
	sink.spawn_train(track_id, func(ok: bool, train_id: int, err: String) -> void:
		if not ok:
			_fail(Loc.t("hint.train_failed", [_reason(err)]) if err != ""
					else Loc.t("hint.train_track_taken"), err)
			return
		trains_changed.emit()
		if train_id >= 0:
			_set_hint(Loc.t("hint.train_placed", [train_id]))
		else:
			_set_hint(Loc.t("hint.train_placed_any"))
	)


func _nearest_train(p: Vector2, max_dist: float) -> int:
	var best := -1
	var best_d := max_dist
	for t in sim.trains():
		var x: float = t["x"]
		var y: float = t["y"]
		var d := p.distance_to(Vector2(x, y))
		if d <= best_d:
			best_d = d
			var tid: int = t["id"]
			best = tid
	return best


func _click_route() -> void:
	var node_id := sim.nearest_node(_ground.x, _ground.y, snap_radius())
	if selected_train >= 0 and node_id >= 0:
		var n := _node(node_id)
		var is_station: bool = n.get("station", false)
		if not is_station:
			_set_hint(Loc.t("hint.route_not_station", [node_id]))
			return
		if not route_stops.is_empty() and route_stops.back() == node_id:
			return
		route_stops.append(node_id)
		draft_changed.emit()
		_set_hint(_default_hint())
		return
	var train_id := _nearest_train(_ground, snap_radius() * 1.5)
	if train_id >= 0:
		select_train(train_id)
		return
	_set_hint(_default_hint())


# --- Hints / drawing ----------------------------------------------------------


func _reset_drafts() -> void:
	chain_active = false
	chain_node = -1
	chain_ref = null
	selected_train = -1
	route_stops.clear()


func _set_hint(text: String) -> void:
	hint = text
	hint_changed.emit(text)


## Shown while an online command is on its way. Locally the result hint
## replaces it before anyone sees it.
func _set_waiting_hint() -> void:
	if sink.is_remote():
		_set_hint(Loc.t("hint.waiting"))


## Shows `text` as the hint and reports the rejected command.
func _fail(text: String, err: String) -> void:
	_set_hint(text)
	command_failed.emit(err)


func _reason(err: String) -> String:
	return ": " + Loc.error(err) if err != "" else ""


## The world changed without our tools (other players online, a resync).
func _on_world_changed() -> void:
	refresh_cache()
	if selected_train >= 0 and not _train_exists(selected_train):
		# Removed by someone else: drop the route draft.
		selected_train = -1
		route_stops.clear()
		draft_changed.emit()
		_set_hint(_default_hint())
	network_changed.emit()
	trains_changed.emit()


func _train_exists(train_id: int) -> bool:
	for t in sim.trains():
		if int(t["id"]) == train_id:
			return true
	return false


func _default_hint() -> String:
	match current_tool:
		Tools.Tool.TRACK:
			if chain_active:
				return Loc.t("hint.track_next")
			return Loc.t("hint.track_start")
		Tools.Tool.STATION:
			return Loc.t("hint.station")
		Tools.Tool.TRAIN:
			return Loc.t("hint.train")
		Tools.Tool.ROUTE:
			if selected_train < 0:
				return Loc.t("hint.route_pick")
			return Loc.t("hint.route_stops", [selected_train, route_stops.size()])
	return Loc.t("hint.none")


func _marker_radius() -> float:
	var d := 1000.0
	if camera is RtsCamera:
		d = (camera as RtsCamera).distance
	return clampf(d * 0.008, 6.0, 90.0)


func _draw_overlay() -> void:
	if overlay == null:
		return
	var r := _marker_radius()
	overlay.begin()
	for id: int in _nodes:
		var n: Dictionary = _nodes[id]
		var is_station: bool = n["station"]
		var c := GroundPick.to_world(_node_pos(id))
		if is_station:
			overlay.square(c, r * 1.3, COLOR_STATION)
		else:
			overlay.ring(c, r, COLOR_NODE)
	if hover_node >= 0 and _nodes.has(hover_node):
		overlay.ring(GroundPick.to_world(_node_pos(hover_node)), r * 1.8, COLOR_HOVER)

	if current_tool == Tools.Tool.TRACK and chain_active and _has_ground:
		var snapped_id := sim.nearest_node(_ground.x, _ground.y, snap_radius())
		var end := _node_pos(snapped_id) if snapped_id >= 0 else _ground
		var ok := chain_pos.distance_to(end) >= MIN_TRACK_LENGTH
		var start_id := _chain_id()
		if snapped_id >= 0 and start_id >= 0:
			ok = ok and snapped_id != start_id and not _track_exists(start_id, snapped_id)
		var col := COLOR_GHOST_OK if ok else COLOR_GHOST_BAD
		overlay.line(GroundPick.to_world(chain_pos), GroundPick.to_world(end), col)
		overlay.ring(GroundPick.to_world(chain_pos), r * 1.2, col)
		overlay.ring(GroundPick.to_world(end), r * 1.2, col)

	if current_tool == Tools.Tool.ROUTE:
		var prev := Vector2.ZERO
		var has_prev := false
		for s in route_stops:
			if not _nodes.has(s):
				continue
			var p := _node_pos(s)
			overlay.ring(GroundPick.to_world(p), r * 2.4, COLOR_ROUTE)
			if has_prev:
				overlay.line(GroundPick.to_world(prev), GroundPick.to_world(p), COLOR_ROUTE)
			prev = p
			has_prev = true
		if selected_train >= 0:
			for t in sim.trains():
				var tid: int = t["id"]
				if tid == selected_train:
					var x: float = t["x"]
					var y: float = t["y"]
					overlay.square(Vector3(x, 0.0, y), r * 2.0, COLOR_ROUTE)
	overlay.end()
