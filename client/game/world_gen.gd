extends RefCounted
## Deterministic start world: towns scattered over the map from a seed.
## The player gets empty land (no tracks) and the default starting money.

const MAP_HALF := 6000.0 ## Towns are placed within +-MAP_HALF metres of the origin.
const MIN_TOWN_DISTANCE := 2500.0 ## Relaxed if the map gets crowded.
const MIN_POPULATION := 500
const MAX_POPULATION := 5000
const MIN_TOWNS := 3
const MAX_TOWNS := 12
## Towns want fairly flat, dry ground: the terrain within TOWN_SITE_RADIUS
## metres may rise and fall at most MAX_SITE_RELIEF metres and stay
## SITE_DRY_MARGIN metres above the water.
const TOWN_SITE_RADIUS := 300.0
const MAX_SITE_RELIEF := 22.0
const SITE_DRY_MARGIN := 3.0
## After this many rejected sites the terrain check is skipped, so a
## rugged map still gets its towns.
const MAX_SITE_REJECTS := 2000


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
	var site_rejects := 0
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
				min_dist *= 0.9 # crowded: accept closer towns rather than loop forever
			continue
		if site_rejects < MAX_SITE_REJECTS and not good_site(sim, p):
			site_rejects += 1
			continue
		placed.append(p)
		# Squaring skews towards small towns: a few big ones, many villages.
		var pop := MIN_POPULATION + int(pow(rng.randf(), 2.0) * (MAX_POPULATION - MIN_POPULATION))
		var name_seed := rng.randi() & 0x7fffffff
		if sim.found_town(p.x, p.y, pop, name_seed):
			founded += 1
	return founded


## `true` if the ground around sim point `p` is flat and dry enough for a town.
static func good_site(sim: SimWorld, p: Vector2) -> bool:
	var water := sim.terrain_water_level()
	var pts := PackedVector2Array([p])
	for ring in [0.5, 1.0]:
		for i in 8:
			var ang := TAU * i / 8.0
			pts.append(p + Vector2(cos(ang), sin(ang)) * TOWN_SITE_RADIUS * ring)
	var h := sim.terrain_heights_at(pts)
	var lo := h[0]
	var hi := h[0]
	for v in h:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return lo > water + SITE_DRY_MARGIN and hi - lo <= MAX_SITE_RELIEF
