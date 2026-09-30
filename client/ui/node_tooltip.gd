extends PanelContainer
## Small tooltip that follows the mouse while it hovers a node or station.

const BuildController := preload("res://gameplay/build_controller.gd")

var controller: BuildController

var _label: Label


func setup(p_controller: BuildController) -> void:
	controller = p_controller
	controller.hover_changed.connect(_on_hover_changed)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)
	visible = false


func _on_hover_changed(node_id: int) -> void:
	if node_id < 0:
		visible = false
		return
	_label.text = controller.describe_node(node_id)
	reset_size()
	visible = true
	_follow_mouse()


func _process(_delta: float) -> void:
	if visible:
		_follow_mouse()


func _follow_mouse() -> void:
	var vp_size := get_viewport_rect().size
	var pos := get_viewport().get_mouse_position() + Vector2(16, 16)
	pos.x = minf(pos.x, vp_size.x - size.x - 4.0)
	pos.y = minf(pos.y, vp_size.y - size.y - 4.0)
	position = pos
