extends Node3D
## Minimal OpenRail client demo: builds a tiny world in the Rust sim and
## renders it. Sim coordinates (x, y) map to Godot's ground plane (x, z).

const TICK_SECONDS := 0.1 # sim runs at 10 Hz

var sim: SimWorld
var train_mesh: MeshInstance3D
var accumulator := 0.0


func _ready() -> void:
	sim = SimWorld.new()
	sim.new_world(1)
	var a := sim.build_node(0.0, 0.0)
	var b := sim.build_node(2000.0, 0.0)
	var track := sim.build_track(a, b)
	var train := sim.spawn_train(track)
	if a < 0 or b < 0 or track < 0 or train < 0:
		push_error("Failed to build demo world")
		return
	_draw_track(Vector3(0, 0, 0), Vector3(2000, 0, 0))
	_create_train()


func _draw_track(from: Vector3, to: Vector3) -> void:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_add_vertex(from)
	mesh.surface_add_vertex(to)
	mesh.surface_end()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.9, 0.9, 0.9)
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = mat
	add_child(inst)


func _create_train() -> void:
	var box := BoxMesh.new()
	box.size = Vector3(60, 12, 12)
	train_mesh = MeshInstance3D.new()
	train_mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.8, 0.15, 0.1)
	train_mesh.material_override = mat
	add_child(train_mesh)


func _process(delta: float) -> void:
	if sim == null or train_mesh == null:
		return
	accumulator += delta
	while accumulator >= TICK_SECONDS:
		accumulator -= TICK_SECONDS
		sim.step()
	var positions := sim.train_positions()
	if positions.size() > 0:
		var p := positions[0]
		train_mesh.position = Vector3(p.x, 6.0, p.y)
