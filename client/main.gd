extends Node3D
## OpenRail phase 1 demo: a ring line with four stations and three trains
## that follow each other under block signals. Sim coordinates (x, y) map
## to Godot's ground plane (x, z).

const GameplayRoot := preload("res://gameplay/gameplay_root.gd")

const TICK_SECONDS := 0.1 # sim runs at 10 Hz

var sim: SimWorld
var train_meshes: Array[MeshInstance3D] = []
var accumulator := 0.0
var track_mesh: MeshInstance3D
var gameplay: GameplayRoot


func _ready() -> void:
	sim = SimWorld.new()
	sim.new_world(1)
	var corners := [Vector2(0, 0), Vector2(3000, 0), Vector2(3000, 2000), Vector2(0, 2000)]
	var stations: Array[int] = []
	for c in corners:
		var node := sim.build_node(c.x, c.y)
		sim.build_station(node)
		stations.append(node)
	var tracks: Array[int] = []
	for i in stations.size():
		tracks.append(sim.build_track(stations[i], stations[(i + 1) % stations.size()]))
	# Three trains on three of the four blocks, each looping the ring.
	for i in 3:
		var train := sim.spawn_train(tracks[i])
		var stops := PackedInt64Array()
		for k in stations.size():
			stops.append(stations[(i + 1 + k) % stations.size()])
		if train < 0 or not sim.set_route(train, stops):
			push_error("Failed to build demo world")
			return
	_draw_tracks()
	for i in 3:
		_create_train(Color.from_hsv(i / 3.0, 0.8, 0.85))
	# Gameplay layer: build tools, line panel and RTS camera input.
	gameplay = GameplayRoot.new()
	add_child(gameplay)
	gameplay.setup(sim, $Camera3D as Camera3D)
	gameplay.network_changed.connect(_draw_tracks)


func _draw_tracks() -> void:
	if track_mesh != null:
		track_mesh.queue_free() # rebuilt after every change to the network
	var segments := sim.track_segments()
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for p in segments:
		mesh.surface_add_vertex(Vector3(p.x, 0, p.y))
	mesh.surface_end()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.9, 0.9, 0.9)
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = mat
	add_child(inst)
	track_mesh = inst


func _create_train(color: Color) -> void:
	var box := BoxMesh.new()
	box.size = Vector3(60, 12, 12)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	var inst := MeshInstance3D.new()
	inst.mesh = box
	inst.material_override = mat
	add_child(inst)
	train_meshes.append(inst)


func _process(delta: float) -> void:
	if sim == null:
		return
	accumulator += delta
	while accumulator >= TICK_SECONDS:
		accumulator -= TICK_SECONDS
		sim.step()
	var positions := sim.train_positions()
	# Trains bought through the build tools get a placeholder box each.
	while train_meshes.size() < positions.size():
		_create_train(Color.from_hsv(fmod(train_meshes.size() * 0.618, 1.0), 0.8, 0.85))
	for i in mini(positions.size(), train_meshes.size()):
		var p := positions[i]
		train_meshes[i].position = Vector3(p.x, 6.0, p.y)
