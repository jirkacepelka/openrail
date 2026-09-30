extends PanelContainer
## Short message near the bottom of the screen that fades out on its own.

const UITheme := preload("res://ui/ui_theme.gd")

const SHOW_SECONDS := 2.6

var _label: Label
var _tween: Tween


func _ready() -> void:
	name = "Toast"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_stylebox_override("panel", UITheme.box(Color(0.35, 0.09, 0.08, 0.95), 8,
			UITheme.DANGER, 10))
	_label = Label.new()
	add_child(_label)
	# Above the bottom toolbar, centred.
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 130)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BEGIN


func show_message(text: String) -> void:
	_label.text = text
	visible = true
	modulate.a = 1.0
	reset_size()
	if _tween != null:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_interval(SHOW_SECONDS)
	_tween.tween_property(self, "modulate:a", 0.0, 0.5)
	_tween.tween_callback(func() -> void: visible = false)
