extends RefCounted
## Utility: raycast from a screen position onto the y = 0 ground plane.
## Sim coordinates (x, y) map to Godot's ground plane (x, z).

const GROUND := Plane(Vector3.UP, 0.0)


## Returns the world point on the ground plane under `screen_pos`, or null if
## the ray does not hit it (camera looking at or above the horizon).
static func pick(camera: Camera3D, screen_pos: Vector2) -> Variant:
	var origin := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	return GROUND.intersects_ray(origin, dir)


## Picks under the current mouse position of the camera's viewport.
static func pick_mouse(camera: Camera3D) -> Variant:
	return pick(camera, camera.get_viewport().get_mouse_position())


## World point to sim metres.
static func to_sim(p: Vector3) -> Vector2:
	return Vector2(p.x, p.z)


## Sim metres to a world point on the ground plane.
static func to_world(p: Vector2, height: float = 0.0) -> Vector3:
	return Vector3(p.x, height, p.y)
