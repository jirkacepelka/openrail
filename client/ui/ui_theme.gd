extends RefCounted
## The one UI theme of the game: dark translucent panels, rounded corners,
## a single accent colour. Session sets it on the root window, so every
## Control (menu, HUD, build toolbar) picks it up.

const PANEL_BG := Color(0.086, 0.106, 0.133, 0.94)
const PANEL_BORDER := Color(1, 1, 1, 0.09)
const BUTTON_BG := Color(0.16, 0.19, 0.23, 1.0)
const BUTTON_HOVER := Color(0.21, 0.25, 0.30, 1.0)
const ACCENT := Color(0.98, 0.62, 0.20) ## Warm signal orange.
const TEXT := Color(0.92, 0.94, 0.96)
const TEXT_DIM := Color(0.62, 0.67, 0.72)
const DANGER := Color(0.92, 0.36, 0.32)


static func box(bg: Color, radius := 8, border := PANEL_BORDER, margin := 10) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.set_border_width_all(1)
	s.border_color = border
	s.set_content_margin_all(margin)
	return s


static func make() -> Theme:
	var t := Theme.new()
	t.default_font_size = 16

	t.set_stylebox("panel", "PanelContainer", box(PANEL_BG))
	t.set_stylebox("panel", "Panel", box(PANEL_BG))
	t.set_stylebox("panel", "PopupPanel", box(PANEL_BG, 8, PANEL_BORDER, 12))
	t.set_stylebox("embedded_border", "Window", box(PANEL_BG, 10, PANEL_BORDER, 14))
	t.set_stylebox("embedded_unfocused_border", "Window", box(PANEL_BG, 10, PANEL_BORDER, 14))
	t.set_color("title_color", "Window", TEXT)
	t.set_constant("title_height", "Window", 34)

	var normal := box(BUTTON_BG, 6, PANEL_BORDER, 8)
	normal.content_margin_left = 14
	normal.content_margin_right = 14
	var hover := box(BUTTON_HOVER, 6, Color(1, 1, 1, 0.18), 8)
	hover.content_margin_left = 14
	hover.content_margin_right = 14
	var pressed := box(ACCENT.darkened(0.25), 6, ACCENT, 8)
	pressed.content_margin_left = 14
	pressed.content_margin_right = 14
	var disabled := box(BUTTON_BG.darkened(0.35), 6, Color(1, 1, 1, 0.04), 8)
	disabled.content_margin_left = 14
	disabled.content_margin_right = 14
	for type_name in ["Button", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", type_name, normal)
		t.set_stylebox("hover", type_name, hover)
		t.set_stylebox("pressed", type_name, pressed)
		t.set_stylebox("hover_pressed", type_name, pressed)
		t.set_stylebox("disabled", type_name, disabled)
		t.set_stylebox("focus", type_name, StyleBoxEmpty.new())
		t.set_color("font_color", type_name, TEXT)
		t.set_color("font_hover_color", type_name, Color.WHITE)
		t.set_color("font_pressed_color", type_name, Color.WHITE)
		t.set_color("font_hover_pressed_color", type_name, Color.WHITE)
		t.set_color("font_disabled_color", type_name, TEXT_DIM.darkened(0.3))

	var field := box(Color(0.05, 0.065, 0.085, 1.0), 6, PANEL_BORDER, 8)
	t.set_stylebox("normal", "LineEdit", field)
	t.set_stylebox("focus", "LineEdit", box(Color(0.05, 0.065, 0.085, 1.0), 6, ACCENT, 8))
	t.set_stylebox("read_only", "LineEdit", field)
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("caret_color", "LineEdit", ACCENT)
	t.set_color("selection_color", "LineEdit", Color(ACCENT, 0.4))

	t.set_color("font_color", "Label", TEXT)
	t.set_color("font_color", "CheckBox", TEXT)
	t.set_constant("separation", "HSeparator", 8)
	return t
