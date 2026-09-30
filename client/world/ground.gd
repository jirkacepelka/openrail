extends RefCounted
## Ground height queries for placing things on the terrain. The terrain is a
## pure function of the world seed computed in the simulation crate
## (`SimWorld.terrain_height`), so it is the same locally, on the server and
## in every remote view. Sim (x, y) maps to Godot (x, z); heights are Godot y.
##
##   const Ground := preload("res://world/ground.gd")
##   var y := Ground.height_at(sim, x, z)


## Ground height in metres at world (x, z). 0 without a world.
static func height_at(sim: SimWorld, x: float, z: float) -> float:
	if sim == null:
		return 0.0
	return sim.terrain_height(x, z)


## World point on the ground at (x, z), lifted by `lift` metres.
static func point_at(sim: SimWorld, x: float, z: float, lift: float = 0.0) -> Vector3:
	return Vector3(x, height_at(sim, x, z) + lift, z)


## Height of the water surface of rivers and lakes.
static func water_level(sim: SimWorld) -> float:
	if sim == null:
		return 0.0
	return sim.terrain_water_level()


## `true` if (x, z) is under water (river or lake).
static func is_water(sim: SimWorld, x: float, z: float) -> bool:
	return height_at(sim, x, z) < water_level(sim)


## Unit surface normal at (x, z), from heights `d` metres apart.
static func normal_at(sim: SimWorld, x: float, z: float, d: float = 4.0) -> Vector3:
	var hx := height_at(sim, x + d, z) - height_at(sim, x - d, z)
	var hz := height_at(sim, x, z + d) - height_at(sim, x, z - d)
	return Vector3(-hx, 2.0 * d, -hz).normalized()


## Slope at (x, z) as rise over run (0 flat, 1 = 45 degrees).
static func slope_at(sim: SimWorld, x: float, z: float, d: float = 4.0) -> float:
	var n := normal_at(sim, x, z, d)
	return sqrt(maxf(0.0, 1.0 - n.y * n.y)) / maxf(n.y, 0.001)
