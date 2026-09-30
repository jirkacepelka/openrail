extends Node3D
## Style sandbox: a small village, trees and a train made of primitives, lit by
## ArtStyle. Use it to judge shader and palette changes without the sim, and
## as a reference scene for new models (drop a model in next to the props).

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	# Track bed and a short train.
	_box(Vector3(0, 0.5, 0), Vector3(400, 1, 6), ArtStyle.PALETTE["soot"])
	for i in 4:
		var x := -60.0 + i * 26.0
		var color: Color = ArtStyle.PALETTE["signal_red"] if i == 0 else ArtStyle.PALETTE["teal"]
		_box(Vector3(x, 4.5, 0), Vector3(24, 7, 5), color)
		_box(Vector3(x, 8.6, 0), Vector3(22, 1.2, 5.4), ArtStyle.PALETTE["brass"])
	_cylinder(Vector3(-66, 10, 0), 1.2, 5, ArtStyle.PALETTE["ink"])
	# Houses along the line.
	for i in 9:
		var x := -150.0 + i * 38.0 + rng.randf_range(-6, 6)
		var z := -30.0 - rng.randf_range(0, 20)
		var h := rng.randf_range(10, 22)
		var wall: Color = [ArtStyle.PALETTE["cream"], ArtStyle.PALETTE["brass"], ArtStyle.PALETTE["copper"]][i % 3]
		_box(Vector3(x, h * 0.5, z), Vector3(18, h, 16), wall)
		_roof(Vector3(x, h, z), Vector3(20, 8, 18), ArtStyle.PALETTE["copper"] if i % 3 != 2 else ArtStyle.PALETTE["teal"])
	# Trees.
	for i in 24:
		var p := Vector3(rng.randf_range(-180, 180), 0, rng.randf_range(15, 120))
		var s := rng.randf_range(0.8, 1.5)
		_cylinder(p + Vector3(0, 4 * s, 0), 0.8 * s, 8 * s, ArtStyle.PALETTE["soot"])
		_sphere(p + Vector3(0, 11 * s, 0), 6 * s, ArtStyle.PALETTE["meadow"].darkened(rng.randf_range(0, 0.3)))
	# A glowing lamp to show off the bloom.
	var lamp := _sphere(Vector3(40, 16, 12), 1.5, ArtStyle.PALETTE["glow_blue"])
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = ArtStyle.PALETTE["glow_blue"] * 4.0
	lamp.material_override = glow
	_cylinder(Vector3(40, 7.5, 12), 0.4, 15, ArtStyle.PALETTE["ink"])


func _mesh(mesh: Mesh, pos: Vector3, color: Color) -> MeshInstance3D:
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.position = pos
	inst.material_override = ArtStyle.paint(color)
	add_child(inst)
	return inst


func _box(pos: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var m := BoxMesh.new()
	m.size = size
	return _mesh(m, pos, color)


func _roof(pos: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var m := PrismMesh.new()
	m.size = size
	return _mesh(m, pos + Vector3(0, size.y * 0.5, 0), color)


func _cylinder(pos: Vector3, radius: float, height: float, color: Color) -> MeshInstance3D:
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	return _mesh(m, pos, color)


func _sphere(pos: Vector3, radius: float, color: Color) -> MeshInstance3D:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	return _mesh(m, pos, color)
