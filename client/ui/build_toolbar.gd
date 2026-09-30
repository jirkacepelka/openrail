extends PanelContainer
## Bottom toolbar in the Train Fever spirit: a hint line and one row of tool
## buttons. Route confirmation buttons appear only while the Route tool is
## active.

const Tools := preload("res://gameplay/tools.gd")
const BuildController := preload("res://gameplay/build_controller.gd")

var controller: BuildController

var _hint_label: Label
var _buttons := {} ## Tool id -> Button
var _route_row: HBoxContainer
var _confirm_button: Button
var _undo_button: Button


func setup(p_controller: BuildController) -> void:
	controller = p_controller
	controller.tool_changed.connect(_on_tool_changed)
	controller.hint_changed.connect(_on_hint_changed)
	controller.draft_changed.connect(_update_route_row)
	_on_hint_changed(controller.hint)
	_update_route_row()


func _ready() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)

	_hint_label = Label.new()
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_hint_label)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)
	_add_tool_button(row, Tools.Tool.TRACK, "1")
	_add_tool_button(row, Tools.Tool.STATION, "2")
	_add_tool_button(row, Tools.Tool.TRAIN, "3")
	_add_tool_button(row, Tools.Tool.ROUTE, "4")
	var bulldoze := _add_tool_button(row, Tools.Tool.BULLDOZE, "")
	bulldoze.disabled = true
	bulldoze.tooltip_text = "Bulldoze is not available yet."

	_route_row = HBoxContainer.new()
	_route_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_route_row.add_theme_constant_override("separation", 6)
	box.add_child(_route_row)
	_undo_button = Button.new()
	_undo_button.text = "Undo stop"
	_undo_button.focus_mode = Control.FOCUS_NONE
	_undo_button.pressed.connect(_on_undo_pressed)
	_route_row.add_child(_undo_button)
	_confirm_button = Button.new()
	_confirm_button.text = "Confirm route (Enter)"
	_confirm_button.focus_mode = Control.FOCUS_NONE
	_confirm_button.pressed.connect(_on_confirm_pressed)
	_route_row.add_child(_confirm_button)
	_route_row.visible = false

	# Bottom centre, growing upwards and sideways as content changes.
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 12)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BEGIN


func _add_tool_button(parent: Control, tool: int, shortcut_hint: String) -> Button:
	var b := Button.new()
	var label: String = Tools.NAMES[tool]
	b.text = label if shortcut_hint.is_empty() else "%s [%s]" % [label, shortcut_hint]
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(96, 44)
	b.toggled.connect(_on_tool_toggled.bind(tool))
	parent.add_child(b)
	_buttons[tool] = b
	return b


func _on_tool_toggled(pressed: bool, tool: int) -> void:
	if controller == null:
		return
	controller.set_tool(tool if pressed else Tools.Tool.NONE)


func _on_tool_changed(tool: int) -> void:
	for id: int in _buttons:
		var b: Button = _buttons[id]
		b.set_pressed_no_signal(id == tool)
	_update_route_row()


func _on_hint_changed(text: String) -> void:
	_hint_label.text = text
	reset_size()


func _update_route_row() -> void:
	if controller == null:
		return
	_route_row.visible = controller.current_tool == Tools.Tool.ROUTE
	_confirm_button.disabled = not controller.can_confirm_route()
	_undo_button.disabled = controller.route_stops.is_empty()
	reset_size()


func _on_confirm_pressed() -> void:
	controller.confirm_route()


func _on_undo_pressed() -> void:
	controller.undo_route_stop()
