extends Control
## Main menu: new game, join a server, settings, quit. Built in code; every
## string comes from Loc so the language setting applies (the menu rebuilds
## itself when the language changes).

const Loc := preload("res://game/loc.gd")
const Settings := preload("res://game/settings.gd")
const WorldGen := preload("res://game/world_gen.gd")
const UITheme := preload("res://ui/ui_theme.gd")

var _new_dialog: ConfirmationDialog
var _join_dialog: ConfirmationDialog
var _settings_dialog: AcceptDialog
var _seed_box: SpinBox
var _towns_box: SpinBox
var _join_fields := {} ## Field name -> LineEdit / SpinBox
var _join_status: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var session := _session()
	if session != null:
		session.status_changed.connect(_on_join_status)
		session.join_failed.connect(_on_join_failed)
	_build()
	if session != null and session.disconnect_reason != "":
		_show_disconnected(session.disconnect_reason)
		session.disconnect_reason = ""


## Tells the player why the online game they were in ended.
func _show_disconnected(reason: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.name = "DisconnectedDialog"
	dialog.title = Loc.t("menu.disconnected_title")
	dialog.dialog_text = Loc.t("menu.disconnected", [reason])
	dialog.ok_button_text = Loc.t("common.ok")
	add_child(dialog)
	dialog.popup_centered.call_deferred()


func _session() -> Node:
	return get_node_or_null("/root/Session")


func _build() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()

	var bg := ColorRect.new()
	bg.color = Color(0.055, 0.07, 0.09)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	# A soft warm band along the bottom, like a horizon at dusk.
	var glow := ColorRect.new()
	glow.color = Color(UITheme.ACCENT, 0.07)
	glow.anchor_top = 0.72
	glow.anchor_right = 1.0
	glow.anchor_bottom = 1.0
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(glow)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	center.add_child(column)

	var title := Label.new()
	title.text = Loc.t("title")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 84)
	title.add_theme_color_override("font_color", UITheme.ACCENT)
	column.add_child(title)
	var subtitle := Label.new()
	subtitle.text = Loc.t("subtitle")
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 20)
	subtitle.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	column.add_child(subtitle)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 28)
	column.add_child(gap)

	_add_button(column, "menu.new_game", _open_new_game, "NewGameButton")
	_add_button(column, "menu.join", _open_join, "JoinButton")
	_add_button(column, "menu.settings", _open_settings, "SettingsButton")
	_add_button(column, "menu.quit", func() -> void: get_tree().quit(), "QuitButton")

	var version := Label.new()
	version.text = Loc.t("menu.version")
	version.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	version.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 14)
	add_child(version)

	_build_new_dialog()
	_build_join_dialog()
	_build_settings_dialog()


func _add_button(parent: Control, key: String, action: Callable, node_name: String) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = Loc.t(key)
	b.custom_minimum_size = Vector2(340, 52)
	b.add_theme_font_size_override("font_size", 20)
	b.pressed.connect(action)
	parent.add_child(b)
	return b


func _row(grid: GridContainer, key: String, field: Control) -> void:
	var l := Label.new()
	l.text = Loc.t(key)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	grid.add_child(l)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(field)


func _grid() -> GridContainer:
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 16)
	g.add_theme_constant_override("v_separation", 10)
	return g


# --- New game -------------------------------------------------------------

func _build_new_dialog() -> void:
	_new_dialog = ConfirmationDialog.new()
	_new_dialog.name = "NewGameDialog"
	_new_dialog.title = Loc.t("new.title")
	_new_dialog.ok_button_text = Loc.t("new.start")
	_new_dialog.cancel_button_text = Loc.t("common.cancel")
	_new_dialog.min_size = Vector2i(460, 0)
	var grid := _grid()
	_new_dialog.add_child(grid)

	_seed_box = SpinBox.new()
	_seed_box.min_value = 0
	_seed_box.max_value = 2147483647
	_seed_box.rounded = true
	_seed_box.value = randi_range(1, 999999999)
	var seed_row := HBoxContainer.new()
	_seed_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_row.add_child(_seed_box)
	var dice := Button.new()
	dice.text = Loc.t("new.random")
	dice.pressed.connect(func() -> void: _seed_box.value = randi_range(1, 999999999))
	seed_row.add_child(dice)
	_row(grid, "new.seed", seed_row)

	_towns_box = SpinBox.new()
	_towns_box.min_value = WorldGen.MIN_TOWNS
	_towns_box.max_value = WorldGen.MAX_TOWNS
	_towns_box.rounded = true
	_towns_box.value = 6
	_row(grid, "new.towns", _towns_box)

	_new_dialog.confirmed.connect(_start_new_game)
	add_child(_new_dialog)


func _open_new_game() -> void:
	_new_dialog.popup_centered()


func _start_new_game() -> void:
	var session := _session()
	if session != null:
		session.start_local(int(_seed_box.value), int(_towns_box.value))


# --- Join -----------------------------------------------------------------

func _build_join_dialog() -> void:
	_join_dialog = ConfirmationDialog.new()
	_join_dialog.name = "JoinDialog"
	_join_dialog.title = Loc.t("join.title")
	_join_dialog.ok_button_text = Loc.t("join.connect")
	_join_dialog.cancel_button_text = Loc.t("common.cancel")
	_join_dialog.min_size = Vector2i(520, 0)
	_join_dialog.dialog_hide_on_ok = false # stays open to show the result
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	_join_dialog.add_child(box)
	var grid := _grid()
	box.add_child(grid)

	var address := LineEdit.new()
	address.text = Settings.join_address
	_join_fields["address"] = address
	_row(grid, "join.address", address)
	var port := SpinBox.new()
	port.min_value = 1
	port.max_value = 65535
	port.rounded = true
	port.value = Settings.join_port
	_join_fields["port"] = port
	_row(grid, "join.port", port)
	var password := LineEdit.new()
	password.secret = true
	_join_fields["password"] = password
	_row(grid, "join.password", password)
	var player := LineEdit.new()
	player.text = Settings.join_name
	_join_fields["name"] = player
	_row(grid, "join.name", player)
	var fingerprint := LineEdit.new()
	fingerprint.text = Settings.join_fingerprint
	_join_fields["fingerprint"] = fingerprint
	_row(grid, "join.fingerprint", fingerprint)

	_join_status = Label.new()
	_join_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_join_status.custom_minimum_size = Vector2(440, 0)
	_join_status.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	box.add_child(_join_status)

	_join_dialog.confirmed.connect(_connect)
	add_child(_join_dialog)


func _open_join() -> void:
	_join_status.text = ""
	_join_dialog.get_ok_button().disabled = false
	_join_dialog.popup_centered()


func _connect() -> void:
	var address: String = (_join_fields["address"] as LineEdit).text.strip_edges()
	if address.is_empty():
		_on_join_failed(Loc.t("join.no_address"))
		return
	var port := int((_join_fields["port"] as SpinBox).value)
	var player: String = (_join_fields["name"] as LineEdit).text.strip_edges()
	var fingerprint: String = (_join_fields["fingerprint"] as LineEdit).text.strip_edges()
	Settings.join_address = address
	Settings.join_port = port
	Settings.join_name = player
	Settings.join_fingerprint = fingerprint
	Settings.save_to_disk() # the password is never stored
	_join_status.remove_theme_color_override("font_color")
	_join_dialog.get_ok_button().disabled = true
	var session := _session()
	if session != null:
		session.join_server(address, port, (_join_fields["password"] as LineEdit).text,
				player, fingerprint)


func _on_join_status(text: String) -> void:
	_join_status.text = text


func _on_join_failed(reason: String) -> void:
	_join_status.text = Loc.t("join.failed", [reason]) if reason != Loc.t("join.no_address") \
			else reason
	_join_status.add_theme_color_override("font_color", UITheme.DANGER)
	_join_dialog.get_ok_button().disabled = false


# --- Settings -------------------------------------------------------------

func _build_settings_dialog() -> void:
	_settings_dialog = AcceptDialog.new()
	_settings_dialog.name = "SettingsDialog"
	_settings_dialog.title = Loc.t("settings.title")
	_settings_dialog.ok_button_text = Loc.t("common.close")
	_settings_dialog.min_size = Vector2i(480, 0)
	var grid := _grid()
	_settings_dialog.add_child(grid)

	var mode := OptionButton.new()
	mode.add_item(Loc.t("settings.windowed"), 0)
	mode.add_item(Loc.t("settings.fullscreen"), 1)
	mode.selected = 1 if Settings.window_mode == "fullscreen" else 0
	mode.item_selected.connect(func(index: int) -> void:
		Settings.window_mode = "fullscreen" if index == 1 else "windowed"
		_settings_changed())
	_row(grid, "settings.window", mode)

	var volume := HSlider.new()
	volume.min_value = 0.0
	volume.max_value = 1.0
	volume.step = 0.01
	volume.value = Settings.master_volume
	volume.custom_minimum_size = Vector2(220, 24)
	volume.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	volume.value_changed.connect(func(v: float) -> void:
		Settings.master_volume = v
		_settings_changed())
	_row(grid, "settings.volume", volume)

	var lang := OptionButton.new()
	var codes: Array = Loc.LANGUAGES.keys()
	for i in codes.size():
		lang.add_item(Loc.LANGUAGES[codes[i]], i)
	lang.selected = maxi(codes.find(Settings.language), 0)
	lang.item_selected.connect(func(index: int) -> void:
		Settings.language = codes[index]
		_settings_changed()
		call_deferred("_rebuild_after_language"))
	_row(grid, "settings.language", lang)
	add_child(_settings_dialog)


func _open_settings() -> void:
	_settings_dialog.popup_centered()


func _settings_changed() -> void:
	Settings.apply()
	Settings.save_to_disk()


func _rebuild_after_language() -> void:
	_build()
	_settings_dialog.popup_centered()
