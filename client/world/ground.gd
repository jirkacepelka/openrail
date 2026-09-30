extends RefCounted
## Ground height lookup shared by everything placed on the terrain.
##
## Fallback until the terrain lands: the world is flat at height 0. The
## terrain work replaces this file with the real height field; callers only
## rely on `height_at`.


## Height of the ground in metres at Godot (x, z) (sim (x, y)).
static func height_at(_sim: SimWorld, _x: float, _z: float) -> float:
	return 0.0
