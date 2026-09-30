extends RefCounted
## Utility: raycast from a screen position onto the terrain.
## Sim coordinates (x, y) map to Godot's ground plane (x, z); the terrain
## height is `SimWorld.terrain_height`. Without a world the ground is the
## y = 0 plane.

const GROUND := Plane(Vector3.UP, 0.0)
const MAX_DISTANCE := 60000.0 ## Rays longer than this miss.
const MAX_STEPS := 400
const REFINE_STEPS := 14


## Returns the world point on the terrain under `screen_pos`, or null if the
## ray does not hit it (looking at the sky).
static func pick(camera: Camera3D, screen_pos: Vector2, sim: SimWorld = null) -> Variant:
	var origin := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if sim == null:
		return GROUND.intersects_ray(origin, dir)
	return ray_terrain(sim, origin, dir)


## Picks under the current mouse position of the camera's viewport.
static func pick_mouse(camera: Camera3D, sim: SimWorld = null) -> Variant:
	return pick(camera, camera.get_viewport().get_mouse_position(), sim)


## First point where the ray from `origin` along unit `dir` meets the
## terrain, or null. Marches in steps that shrink as the ray nears the
## ground, then refines the crossing by bisection.
static func ray_terrain(sim: SimWorld, origin: Vector3, dir: Vector3) -> Variant:
	var top := sim.terrain_max_height() + 1.0
	var t := 0.0
	if origin.y > top:
		if dir.y >= -1e-4:
			return null
		t = (top - origin.y) / dir.y # skip the empty air above every hill
	var t_end := MAX_DISTANCE
	if dir.y < -1e-4:
		t_end = minf(t_end, (0.0 - 1.0 - origin.y) / dir.y) # below the lowest ground
	var gap := _gap(sim, origin, dir, t)
	if gap < 0.0:
		return _point(sim, origin, dir, t) # starts underground
	for i in MAX_STEPS:
		if t >= t_end:
			return null
		# The ground rises at most about one metre per metre, so moving a bit
		# less than the gap never jumps through a hill.
		var step := maxf(gap * 0.55, 1.0 + t * 0.001)
		var t_next := minf(t + step, t_end)
		var gap_next := _gap(sim, origin, dir, t_next)
		if gap_next <= 0.0:
			var lo := t
			var hi := t_next
			for j in REFINE_STEPS:
				var mid := (lo + hi) * 0.5
				if _gap(sim, origin, dir, mid) > 0.0:
					lo = mid
				else:
					hi = mid
			return _point(sim, origin, dir, hi)
		t = t_next
		gap = gap_next
	return null


## Height of the ray above the ground at distance `t`.
static func _gap(sim: SimWorld, origin: Vector3, dir: Vector3, t: float) -> float:
	var p := origin + dir * t
	return p.y - sim.terrain_height(p.x, p.z)


static func _point(sim: SimWorld, origin: Vector3, dir: Vector3, t: float) -> Vector3:
	var p := origin + dir * t
	return Vector3(p.x, sim.terrain_height(p.x, p.z), p.z)


## World point to sim metres.
static func to_sim(p: Vector3) -> Vector2:
	return Vector2(p.x, p.z)


## Sim metres to a world point, `height` metres up (use
## world/ground.gd for the terrain height).
static func to_world(p: Vector2, height: float = 0.0) -> Vector3:
	return Vector3(p.x, height, p.y)
