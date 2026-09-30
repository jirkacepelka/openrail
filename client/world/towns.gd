extends Node3D
## Draws every town of the world as streets, buildings, gardens and fields.
##
## Each town is laid out by `towns_layout.gd` (deterministic from its centre,
## name and population) and meshed by `towns_mesh.gd`. Per town there is one
## node at the town centre with four merged meshes:
## - `Ground`: streets, square, yards and fields, always drawn,
## - `Buildings`: walls, roofs and foundations, up to `DETAIL_END` metres,
## - `Details`: windows, doors and chimneys, up to `OPENINGS_END` metres,
## - `Cluster`: one low-poly box per building, beyond `DETAIL_END`.
## Nothing here changes the simulation.

const Layout := preload("res://world/towns_layout.gd")
const Builder := preload("res://world/towns_mesh.gd")

const DETAIL_END := 2600.0 ## Full buildings up to this camera distance (m).
const OPENINGS_END := 1500.0 ## Windows and doors up to this distance (m).
const LOD_MARGIN := 150.0

var sim: SimWorld
var _towns: Array[Dictionary] = [] ## {key, node, layout}


func setup(p_sim: SimWorld) -> void:
	sim = p_sim
	sync()


## Builds towns that are new or changed since the last call. Cheap when
## nothing changed; call it whenever the town list may have changed.
func sync() -> void:
	if sim == null:
		return
	var pos := sim.town_positions()
	var names := sim.town_names()
	var pops := sim.town_populations()
	for i in pos.size():
		var key := "%s|%.1f|%.1f|%d" % [names[i], pos[i].x, pos[i].y, pops[i]]
		if i < _towns.size() and _towns[i]["key"] == key:
			continue
		var layout := Layout.generate(pos[i], names[i], pops[i])
		var node := _build_node(layout, names[i])
		var entry := {"key": key, "node": node, "layout": layout}
		if i < _towns.size():
			(_towns[i]["node"] as Node).queue_free()
			_towns[i] = entry
		else:
			_towns.append(entry)
	while _towns.size() > pos.size():
		(_towns.pop_back()["node"] as Node).queue_free()


## Number of towns drawn.
func town_count() -> int:
	return _towns.size()


## The layout of town `i` (see `towns_layout.gd`), e.g. for its
## `station_plot`, the area kept free for a station.
func layout(i: int) -> Dictionary:
	return _towns[i]["layout"] if i >= 0 and i < _towns.size() else {}


## The node of town `i` (children Ground, Buildings, Details, Cluster).
func town_node(i: int) -> Node3D:
	return _towns[i]["node"] if i >= 0 and i < _towns.size() else null


func _build_node(layout: Dictionary, town_name: String) -> Node3D:
	var built := Builder.build(layout, sim)
	var center: Vector2 = layout["center"]
	var root := Node3D.new()
	root.name = "Town_" + town_name.validate_node_name()
	root.position = Vector3(center.x, 0.0, center.y)
	_add(root, "Ground", built.flat, 0.0, 0.0, false)
	_add(root, "Buildings", built.buildings, 0.0, DETAIL_END, true)
	_add(root, "Details", built.details, 0.0, OPENINGS_END, false)
	_add(root, "Cluster", built.cluster, DETAIL_END, 0.0, true)
	add_child(root)
	return root


func _add(root: Node3D, node_name: String, surfaces: Builder.Surfaces, begin: float, end: float,
		shadows: bool) -> void:
	if surfaces.vertex_count() == 0:
		return
	var inst := MeshInstance3D.new()
	inst.name = node_name
	inst.mesh = surfaces.to_mesh()
	inst.visibility_range_begin = begin
	inst.visibility_range_end = end
	if begin > 0.0:
		inst.visibility_range_begin_margin = LOD_MARGIN
	if end > 0.0:
		inst.visibility_range_end_margin = LOD_MARGIN
	inst.cast_shadow = (GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	root.add_child(inst)
