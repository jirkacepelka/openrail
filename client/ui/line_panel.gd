extends PanelContainer
## Small panel at the top right listing all trains and their stops. Each row
## can jump the camera to the train or start editing its route.

const Tools := preload("res://gameplay/tools.gd")
const BuildController := preload("res://gameplay/build_controller.gd")

var controller: BuildController

var _list: VBoxContainer
var _scroll: ScrollContainer
var _signature := ""
var _timer: Timer


func setup(p_controller: BuildController) -> void:
	controller = p_controller
	controller.trains_changed.connect(refresh)
	controller.network_changed.connect(refresh)
	controller.draft_changed.connect(refresh)
	refresh()


func _ready() -> void:
	custom_minimum_size = Vector2(280, 0)
	var box := VBoxContainer.new()
	add_child(box)
	var title := Label.new()
	title.text = "Trains and lines"
	box.add_child(title)
	box.add_child(HSeparator.new())
	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(0, 40)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)

	# Top right corner; grows downwards, capped so it never covers the toolbar.
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 12)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grow_vertical = Control.GROW_DIRECTION_END

	# Routes change inside the sim (for example after a set_route), so poll
	# lightly in addition to the controller signals.
	_timer = Timer.new()
	_timer.wait_time = 1.0
	_timer.timeout.connect(refresh)
	add_child(_timer)
	_timer.start()


func refresh() -> void:
	if controller == null or controller.sim == null or _list == null:
		return
	var trains := controller.sim.trains()
	var sig := str(controller.selected_train)
	for t in trains:
		sig += "|%s:%s:%s" % [t["id"], t["track"], t["stops"]]
	if sig == _signature:
		return
	_signature = sig

	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	if trains.is_empty():
		var empty := Label.new()
		empty.text = "No trains yet. Use the Train tool on a track."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.custom_minimum_size = Vector2(250, 0)
		_list.add_child(empty)
	for t in trains:
		_list.add_child(_make_row(t))
	# A ScrollContainer does not size itself to its content, so do it here.
	_scroll.custom_minimum_size.y = clampf(_list.get_combined_minimum_size().y, 40.0, 360.0)
	reset_size()


func _make_row(t: Dictionary) -> Control:
	var id: int = t["id"]
	var stops: PackedInt64Array = t["stops"]
	var row := VBoxContainer.new()

	var head := HBoxContainer.new()
	row.add_child(head)
	var name_label := Label.new()
	name_label.text = "Train %d" % id
	if id == controller.selected_train:
		name_label.text += " (editing)"
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_label)
	var focus := Button.new()
	focus.text = "Show"
	focus.focus_mode = Control.FOCUS_NONE
	focus.pressed.connect(controller.focus_train.bind(id))
	head.add_child(focus)
	var edit := Button.new()
	edit.text = "Route"
	edit.focus_mode = Control.FOCUS_NONE
	edit.pressed.connect(controller.select_train.bind(id))
	head.add_child(edit)

	var stops_label := Label.new()
	stops_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stops_label.custom_minimum_size = Vector2(250, 0)
	if stops.is_empty():
		stops_label.text = "No route (shuttles on track %d)" % int(t["track"])
	else:
		var names := PackedStringArray()
		for s in stops:
			names.append(controller.station_label(s))
		stops_label.text = " > ".join(names)
	row.add_child(stops_label)
	row.add_child(HSeparator.new())
	return row
