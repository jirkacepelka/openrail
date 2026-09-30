extends Node
## Entry point for the gameplay layer. main.gd instances one of these and
## calls setup(); everything else (controller, overlay, UI) is created here.

const BuildController := preload("res://gameplay/build_controller.gd")
const BuildOverlay := preload("res://gameplay/build_overlay.gd")
const BuildToolbar := preload("res://ui/build_toolbar.gd")
const LinePanel := preload("res://ui/line_panel.gd")
const NodeTooltip := preload("res://ui/node_tooltip.gd")

## Emitted after the track network changed; redraw the network rendering.
signal network_changed
## Emitted after trains were added or their routes changed.
signal trains_changed

var controller: BuildController


func setup(sim: SimWorld, camera: Camera3D) -> void:
	var overlay := BuildOverlay.new()
	overlay.name = "BuildOverlay"
	add_child(overlay)

	controller = BuildController.new()
	controller.name = "BuildController"
	add_child(controller)
	controller.setup(sim, camera, overlay)
	controller.network_changed.connect(network_changed.emit)
	controller.trains_changed.connect(trains_changed.emit)

	var layer := CanvasLayer.new()
	layer.name = "BuildUI"
	layer.layer = 10
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	var toolbar := BuildToolbar.new()
	root.add_child(toolbar)
	toolbar.setup(controller)
	var lines := LinePanel.new()
	root.add_child(lines)
	lines.setup(controller)
	var tooltip := NodeTooltip.new()
	root.add_child(tooltip)
	tooltip.setup(controller)
