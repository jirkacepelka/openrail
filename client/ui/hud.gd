extends PanelContainer
## Top bar: menu button, company balance, date and the game speed buttons.
##
## Keys: Space toggles pause, F1 pause, F2 1x, F3 2x, F4 4x, + / - one speed
## step faster / slower. (1..4 belong to the build tools.)

const Loc := preload("res://game/loc.gd")
const UITheme := preload("res://ui/ui_theme.gd")

const SPEED_KEYS := {KEY_F1: 0, KEY_F2: 1, KEY_F3: 2, KEY_F4: 4}

var session: Node

var _balance: Label
var _date: Label
var _speed_buttons := {} ## speed -> Button
var _leave_dialog: ConfirmationDialog
var _resume_speed := 1


func setup(p_session: Node) -> void:
	session = p_session
	session.speed_changed.connect(_on_speed_changed)
	_on_speed_changed(session.speed)
	_refresh()


func _ready() -> void:
	name = "Hud"
	set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE, Control.PRESET_MODE_MINSIZE, 8)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	add_child(row)

	var menu := Button.new()
	menu.name = "MenuButton"
	menu.text = Loc.t("hud.menu")
	menu.focus_mode = Control.FOCUS_NONE
	menu.pressed.connect(func() -> void: _leave_dialog.popup_centered())
	row.add_child(menu)
	row.add_child(_spacer())

	_balance = Label.new()
	_balance.name = "Balance"
	_balance.tooltip_text = Loc.t("hud.balance")
	_balance.add_theme_font_size_override("font_size", 22)
	_balance.add_theme_color_override("font_color", UITheme.ACCENT)
	_balance.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(_balance)
	_date = Label.new()
	_date.name = "Date"
	_date.tooltip_text = Loc.t("hud.date")
	_date.add_theme_font_size_override("font_size", 20)
	_date.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(_date)
	row.add_child(_spacer())

	var group := ButtonGroup.new()
	for speed: int in [0, 1, 2, 4]:
		var b := Button.new()
		b.name = "Speed%d" % speed
		b.text = Loc.t("hud.pause") if speed == 0 else "%dx" % speed
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(56, 0)
		var key := "F%d" % (1 if speed == 0 else (2 if speed == 1 else (3 if speed == 2 else 4)))
		b.tooltip_text = key
		b.pressed.connect(func() -> void: session.set_speed(speed))
		row.add_child(b)
		_speed_buttons[speed] = b

	_leave_dialog = ConfirmationDialog.new()
	_leave_dialog.title = Loc.t("hud.leave_title")
	_leave_dialog.dialog_text = Loc.t("hud.leave_text")
	_leave_dialog.ok_button_text = Loc.t("hud.leave_yes")
	_leave_dialog.cancel_button_text = Loc.t("common.cancel")
	_leave_dialog.confirmed.connect(func() -> void: session.leave_to_menu())
	add_child(_leave_dialog)


func _spacer() -> Control:
	var s := Control.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s


func _process(_delta: float) -> void:
	_refresh()


func _refresh() -> void:
	if session == null or session.world == null:
		return
	var w: SimWorld = session.world
	_balance.text = Loc.money(w.balance())
	_date.text = w.date_string()
	var remote: bool = session.is_remote()
	for speed: int in _speed_buttons:
		(_speed_buttons[speed] as Button).disabled = remote
	if remote:
		_date.tooltip_text = Loc.t("hud.remote_speed")


func _on_speed_changed(speed: int) -> void:
	if speed > 0:
		_resume_speed = speed
	if _speed_buttons.has(speed):
		(_speed_buttons[speed] as Button).set_pressed_no_signal(true)


func _unhandled_key_input(event: InputEvent) -> void:
	if session == null or session.is_remote():
		return
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if SPEED_KEYS.has(k.keycode):
		session.set_speed(SPEED_KEYS[k.keycode])
	elif k.keycode == KEY_SPACE:
		session.set_speed(0 if session.speed > 0 else _resume_speed)
	elif k.keycode == KEY_EQUAL or k.keycode == KEY_PLUS or k.keycode == KEY_KP_ADD:
		_step_speed(1)
	elif k.keycode == KEY_MINUS or k.keycode == KEY_KP_SUBTRACT:
		_step_speed(-1)
	else:
		return
	get_viewport().set_input_as_handled()


func _step_speed(direction: int) -> void:
	var i: int = session.SPEEDS.find(session.speed)
	session.set_speed(session.SPEEDS[clampi(i + direction, 0, session.SPEEDS.size() - 1)])
