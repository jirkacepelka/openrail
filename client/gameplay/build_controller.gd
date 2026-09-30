extends Node
## Build tools controller: Track, Station, Train and Route tools plus hover
## picking. All world changes go through the SimWorld command bindings; this
## node only keeps a cached copy of nodes / tracks for picking and drawing.

const Tools := preload("res://gameplay/tools.gd")
const GroundPick := preload("res://gameplay/ground_pick.gd")
const RtsCamera := preload("res://gameplay/rts_camera.gd")
const BuildOverlay := preload("res://gameplay/build_overlay.gd")

## Emitted after nodes or tracks changed (rebuild the network rendering).
signal network_changed
## Emitted after trains or their routes changed.
signal trains_changed
signal tool_changed(tool: int)
signal hint_changed(text: String)
## Route draft (selected train / chosen stops) changed.
signal draft_changed
signal hover_changed(node_id: int)

const MIN_TRACK_LENGTH := 20.0 ## Metres.
const COLOR_NODE := Color(0.85, 0.85, 0.85, 0.9)
const COLOR_STATION := Color(1.0, 0.85, 0.2, 1.0)
const COLOR_HOVER := Color(0.3, 0.9, 1.0, 1.0)
const COLOR_GHOST_OK := Color(0.4, 1.0, 0.4, 1.0)
const COLOR_GHOST_BAD := Color(1.0, 0.35, 0.3, 1.0)
const COLOR_ROUTE := Color(1.0, 0.55, 0.15, 1.0)

var sim: SimWorld
var camera: Camera3D
var overlay: BuildOverlay

var current_tool: int = Tools.Tool.NONE
var hint := ""
var hover_node := -1

# Track tool state (a "chain" starts with the first click).
var chain_active := false
var chain_node := -1 ## Existing node id, or -1 if the start is a free point.
var chain_pos := Vector2.ZERO

# Route tool state.
var selected_train := -1
var route_stops: Array[int] = []

var _nodes: Dictionary = {} ## id -> Dictionary {id, x, y, station}
var _tracks: Array[Dictionary] = []
var _has_ground := false
var _ground := Vector2.ZERO


func setup(p_sim: SimWorld, p_camera: Camera3D, p_overlay: BuildOverlay) -> void:
	sim = p_sim
	camera = p_camera
	overlay = p_overlay
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
		_set_hint("A route needs a train and at least two stations.")
		return
	var stops := PackedInt64Array()
	for s in route_stops:
		stops.append(s)
	if sim.set_route(selected_train, stops):
		var id := selected_train
		selected_train = -1
		route_stops.clear()
		draft_changed.emit()
		trains_changed.emit()
		_set_hint("Route set for train %d. Select another train or press Esc." % id)
	else:
		_set_hint("The route was rejected by the simulation.")


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
	return "Station %d" % node_id


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
	lines.append(station_label(node_id) if is_station else "Junction %d" % node_id)
	lines.append("Position: %d, %d m" % [roundi(x), roundi(y)])
	lines.append("Tracks: %d" % links)
	if is_station:
		var served := PackedStringArray()
		for t in sim.trains():
			var stops: PackedInt64Array = t["stops"]
			if stops.has(node_id):
				served.append(str(t["id"]))
		lines.append("Trains: %s" % (", ".join(served) if not served.is_empty() else "none"))
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
	var hit: Variant = GroundPick.pick_mouse(camera)
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


func _node_pos(id: int) -> Vector2:
	var n: Dictionary = _nodes[id]
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
		_set_hint(_default_hint())
		return
	if snapped_id >= 0 and snapped_id == chain_node:
		return
	if chain_pos.distance_to(pos) < MIN_TRACK_LENGTH:
		_set_hint("Too short. Tracks need at least %d m." % int(MIN_TRACK_LENGTH))
		return
	if snapped_id >= 0 and chain_node >= 0 and _track_exists(chain_node, snapped_id):
		_set_hint("There is already a track between those nodes.")
		return
	var a := chain_node
	if a < 0:
		a = sim.build_node(chain_pos.x, chain_pos.y)
	var b := snapped_id
	if b < 0:
		b = sim.build_node(pos.x, pos.y)
	if a < 0 or b < 0 or sim.build_track(a, b) < 0:
		_set_hint("Could not build that track.")
		refresh_cache()
		network_changed.emit()
		chain_active = false
		return
	refresh_cache()
	# Chain: the end of this track is the start of the next one.
	chain_node = b
	chain_pos = _node_pos(b)
	_set_hint(_default_hint())
	network_changed.emit()


func _click_station() -> void:
	var id := sim.nearest_node(_ground.x, _ground.y, snap_radius())
	if id < 0:
		_set_hint("Click on a track node to make it a station.")
		return
	var n: Dictionary = _nodes[id]
	var is_station: bool = n["station"]
	if is_station:
		_set_hint("Node %d is already a station." % id)
		return
	if sim.build_station(id):
		refresh_cache()
		_set_hint("Station %d built." % id)
		network_changed.emit()
	else:
		_set_hint("Could not build a station there.")


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
		_set_hint("Click on a track to place a train.")
		return
	var train_id := sim.spawn_train(track_id)
	if train_id < 0:
		_set_hint("That track already has a train.")
		return
	trains_changed.emit()
	_set_hint("Train %d placed. Use the Route tool to send it between stations." % train_id)


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
		var n: Dictionary = _nodes[node_id]
		var is_station: bool = n["station"]
		if not is_station:
			_set_hint("Node %d is not a station. Build one with the Station tool." % node_id)
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
	selected_train = -1
	route_stops.clear()


func _set_hint(text: String) -> void:
	hint = text
	hint_changed.emit(text)


func _default_hint() -> String:
	match current_tool:
		Tools.Tool.TRACK:
			if chain_active:
				return "Click to place the next point. Right click or Esc ends the line."
			return "Click a point or an existing node to start a track."
		Tools.Tool.STATION:
			return "Click a node to turn it into a station."
		Tools.Tool.TRAIN:
			return "Click a track to place a train."
		Tools.Tool.ROUTE:
			if selected_train < 0:
				return "Click a train (or pick one in the list), then choose stations in order."
			return "Train %d: click stations in order (%d chosen). Enter confirms." % [
				selected_train, route_stops.size()
			]
	return "Pick a tool below. WASD pans, wheel zooms, middle mouse rotates."


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
		if snapped_id >= 0 and chain_node >= 0:
			ok = ok and snapped_id != chain_node and not _track_exists(chain_node, snapped_id)
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
