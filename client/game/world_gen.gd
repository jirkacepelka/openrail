extends RefCounted
## Deterministic start world: towns scattered over the map from a seed.
## The player gets empty land (no tracks) and the default starting money.

const MAP_HALF := 6000.0 ## Towns are placed within +-MAP_HALF metres of the origin.
const MIN_TOWN_DISTANCE := 2500.0 ## Relaxed if the map gets crowded.
## Never closer than this: a big town with its ring of fields is about 900 m
## in radius (see world/towns_layout.gd).
const MIN_TOWN_DISTANCE_FLOOR := 2000.0
const MIN_POPULATION := 500
const MAX_POPULATION := 5000
const MIN_TOWNS := 3
const MAX_TOWNS := 12


## Creates a fresh world in `sim` from `seed_value` and founds `towns` towns.
## Returns the number of towns actually founded.
static func generate(sim: SimWorld, seed_value: int, towns: int) -> int:
	sim.new_world(seed_value)
	towns = clampi(towns, MIN_TOWNS, MAX_TOWNS)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var placed: Array[Vector2] = []
	var min_dist := MIN_TOWN_DISTANCE
	var founded := 0
	var attempts := 0
	while placed.size() < towns:
		var p := Vector2(
			snappedf(rng.randf_range(-MAP_HALF, MAP_HALF), 10.0),
			snappedf(rng.randf_range(-MAP_HALF, MAP_HALF), 10.0))
		var ok := true
		for q in placed:
			if p.distance_to(q) < min_dist:
				ok = false
				break
		attempts += 1
		if not ok:
			if attempts % 200 == 0:
				# Crowded: accept closer towns rather than loop forever.
				min_dist = maxf(min_dist * 0.9, MIN_TOWN_DISTANCE_FLOOR)
			continue
		placed.append(p)
		# Squaring skews towards small towns: a few big ones, many villages.
		var pop := MIN_POPULATION + int(pow(rng.randf(), 2.0) * (MAX_POPULATION - MIN_POPULATION))
		var name_seed := rng.randi() & 0x7fffffff
		if sim.found_town(p.x, p.y, pop, name_seed):
			founded += 1
	return founded
