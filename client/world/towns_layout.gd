class_name TownsLayout
extends RefCounted
## Deterministic town layout: streets, buildings, yards and fields for one
## town, computed from its centre, name and population only. Pure 2D in sim
## metres (Godot x, z); heights are added later by `towns_mesh.gd`. The same
## input gives the same layout on every run and every client, and nothing
## here touches the simulation.
##
## Structure: a paved square with the church in the middle, 3 to 5 main
## streets radiating from the square, a ring street (and an outer partial ring
## in bigger towns), organic side lanes, buildings along the street frontage
## (apartment blocks around the centre, row houses, family houses with
## gardens, barns and workshops at the edge), a clear plot near the centre
## for a future station, and a ring of crop fields outside the built area.

## Street kinds.
enum Street { MAIN, RING, LANE, ROAD }
## Building kinds.
enum Kind { HOUSE, ROW, APARTMENT, BARN, WORKSHOP, CHURCH, HALL }
## Roof shapes.
enum Roof { GABLE, HIP }

## Street half widths (m), by `Street`.
const HALF_WIDTH := {Street.MAIN: 4.5, Street.RING: 3.2, Street.LANE: 2.6, Street.ROAD: 3.0}
const SIDEWALK := 1.5 ## Between the street edge and a building front, in town.
const STATION_PLOT_SIZE := Vector2(200.0, 50.0) ## Kept free of buildings.
const GRID_CELL := 40.0

## Palette sizes; the mesh builder maps indices to materials.
const WALL_COLOURS := 6
const ROOF_COLOURS := 5
const YARD_COLOURS := 3
const FIELD_COLOURS := 7

var _rng := RandomNumberGenerator.new()
var _center := Vector2.ZERO
var _radius := 150.0
var _pop := 500

var _streets: Array[Dictionary] = []
var _seg_grid := {} ## Vector2i -> Array of [a, b, half_width, street index]
var _rects: Array[Dictionary] = [] ## buildings, yards, reserved areas (for overlap tests)
var _rect_grid := {} ## Vector2i -> Array of rect indices
var _buildings: Array[Dictionary] = []
var _yards: Array[Dictionary] = []
var _fields: Array[Dictionary] = []


## Layout for a town. Returns a Dictionary:
## - `center` (Vector2), `radius` (built-up radius in m), `field_radius`
##   (outer radius of the fields),
## - `streets`: Array of {points: PackedVector2Array, half_width, kind},
## - `square`, `station_plot`: rect {pos, angle, size},
## - `buildings`: Array of rect + {kind, floors, wall_height, roof, pitch,
##   ridge_x, wall, roof_colour}; rear wings of a house also have `wing`,
## - `yards`, `fields`: Array of rect + {colour}.
## A rect is centred at `pos`, its local x axis at `angle` (radians), `size`
## is (x extent, y extent). For buildings local -y is the street front.
static func generate(center: Vector2, town_name: String, population: int) -> Dictionary:
	var l := new()
	return l._generate(center, town_name, population)


## The seed for a town, from its name and position (stable across platforms).
static func town_seed(center: Vector2, town_name: String) -> int:
	var key := "%s|%d|%d" % [town_name, roundi(center.x), roundi(center.y)]
	return key.hash()


## Built-up radius in metres for a population (about 150 m at 500 people,
## 400 m at 5000).
static func radius_for(population: int) -> float:
	return 150.0 * pow(maxf(float(population), 100.0) / 500.0, 0.43)


func _generate(center: Vector2, town_name: String, population: int) -> Dictionary:
	_rng.seed = town_seed(center, town_name)
	_center = center
	_pop = maxi(population, 100)
	_radius = radius_for(_pop)

	var base_angle := _rng.randf() * TAU
	var big := _pop >= 2000
	var sq_size := Vector2(72.0, 52.0) if big else Vector2(50.0, 38.0)
	var square := _rect(center, base_angle, sq_size)
	_reserve(square)

	var main_count := 3 if _pop < 1200 else (4 if _pop < 3500 else 5)
	var angles: Array[float] = []
	for i in main_count:
		angles.append(base_angle + TAU * i / main_count + _rng.randf_range(-0.28, 0.28))
	var station_dir := _largest_gap_bisector(angles)
	var plot_dist := sq_size.length() * 0.5 + 45.0
	var plot := _rect(center + Vector2.from_angle(station_dir) * plot_dist,
			station_dir + PI * 0.5, STATION_PLOT_SIZE)
	_reserve(plot)

	_add_church(square, big)

	var field_in := _radius * 0.95 + 15.0
	var field_out := field_in + 230.0 + 90.0 * sqrt(_pop / 500.0)
	# Main streets, continued out as country roads through the fields.
	var mains: Array[PackedVector2Array] = []
	for a in angles:
		var start := _square_exit(square, a)
		var main := _walk(start, a, _radius * _rng.randf_range(1.1, 1.3) - start.distance_to(center),
				18.0, 0.1)
		_add_street(main, Street.MAIN)
		mains.append(main)
		var tail := main[main.size() - 1]
		var heading := (tail - main[main.size() - 2]).angle()
		var road := _walk(tail, heading, field_out + 180.0 - tail.distance_to(center), 30.0, 0.05)
		_add_street(road, Street.ROAD)
	# Cross streets between neighbouring main streets, at a different
	# distance in every sector so they never form a neat circle.
	var order: Array[int] = []
	for i in main_count:
		order.append(i)
	order.sort_custom(func(x: int, y: int) -> bool: return fposmod(angles[x], TAU) < fposmod(angles[y], TAU))
	var inner := 0 if _pop < 900 else (main_count - 2 if _pop < 1400 else main_count)
	var skip := _rng.randi_range(0, main_count - 1)
	for k in main_count:
		var i := order[k]
		var j := order[(k + 1) % main_count]
		var mid := angles[i] + fposmod(angles[j] - angles[i], TAU) * 0.5
		var r_min := plot_dist + 50.0 if absf(angle_difference(mid, station_dir)) < 0.3 else 0.0
		if (k + skip) % main_count < inner:
			var r := maxf(_radius * _rng.randf_range(0.38, 0.62), r_min)
			_connect(mains[i], mains[j], r, r * _rng.randf_range(0.9, 1.2), mid)
		if _pop >= 2500 and r_min == 0.0 and _rng.randf() < 0.8:
			var r1 := _radius * _rng.randf_range(0.2, 0.28)
			_connect(mains[i], mains[j], r1, r1 * _rng.randf_range(0.85, 1.15), mid)
		if _pop >= 3000 and _rng.randf() < 0.75:
			var r2 := _radius * _rng.randf_range(0.78, 0.92)
			_connect(mains[i], mains[j], r2, r2 * _rng.randf_range(0.9, 1.1), mid)
	# Side lanes.
	var lanes := maxi(int(_pop / 200.0) - 1, 1)
	var attempts := 0
	var made := 0
	while made < lanes and attempts < lanes * 8:
		attempts += 1
		if _try_lane(square, plot):
			made += 1

	# Buildings: square first, then streets from the centre out.
	_front_square(square, big)
	for kind: int in [Street.MAIN, Street.RING, Street.LANE, Street.ROAD]:
		for i in _streets.size():
			if _streets[i]["kind"] == kind:
				_front_street(i, 1.0)
				_front_street(i, -1.0)

	_add_fields(field_in, field_out, angles)

	return {
		"center": center,
		"radius": _radius,
		"field_radius": field_out,
		"streets": _streets,
		"square": square,
		"station_plot": plot,
		"buildings": _buildings,
		"yards": _yards,
		"fields": _fields,
	}


# --- geometry helpers ------------------------------------------------------

static func _rect(pos: Vector2, angle: float, size: Vector2) -> Dictionary:
	return {"pos": pos, "angle": angle, "size": size}


static func _axes(r: Dictionary) -> Array[Vector2]:
	var a: float = r["angle"]
	return [Vector2(cos(a), sin(a)), Vector2(-sin(a), cos(a))]


## The four corners of a rect, counter-clockwise from local (-x, -y).
static func corners(r: Dictionary) -> PackedVector2Array:
	var ax := _axes(r)
	var h: Vector2 = r["size"] * 0.5
	var p: Vector2 = r["pos"]
	var x := ax[0] * h.x
	var y := ax[1] * h.y
	return PackedVector2Array([p - x - y, p + x - y, p + x + y, p - x + y])


static func _overlap(a: Dictionary, b: Dictionary) -> bool:
	var ca := corners(a)
	var cb := corners(b)
	for ax in _axes(a) + _axes(b):
		var amin := INF
		var amax := -INF
		var bmin := INF
		var bmax := -INF
		for p in ca:
			var d := p.dot(ax)
			amin = minf(amin, d)
			amax = maxf(amax, d)
		for p in cb:
			var d := p.dot(ax)
			bmin = minf(bmin, d)
			bmax = maxf(bmax, d)
		if amax <= bmin or bmax <= amin:
			return false
	return true


## Distance from segment a-b to rect r (0 if they touch).
static func _segment_rect_distance(a: Vector2, b: Vector2, r: Dictionary) -> float:
	var ax := _axes(r)
	var h: Vector2 = r["size"] * 0.5
	var p: Vector2 = r["pos"]
	var la := Vector2((a - p).dot(ax[0]), (a - p).dot(ax[1]))
	var lb := Vector2((b - p).dot(ax[0]), (b - p).dot(ax[1]))
	# Liang-Barsky clip: does the segment cross the box?
	var t0 := 0.0
	var t1 := 1.0
	var d := lb - la
	var crosses := true
	for k in 4:
		var pk: float
		var qk: float
		match k:
			0:
				pk = -d.x
				qk = la.x + h.x
			1:
				pk = d.x
				qk = h.x - la.x
			2:
				pk = -d.y
				qk = la.y + h.y
			_:
				pk = d.y
				qk = h.y - la.y
		if absf(pk) < 1e-9:
			if qk < 0.0:
				crosses = false
				break
		else:
			var t := qk / pk
			if pk < 0.0:
				t0 = maxf(t0, t)
			else:
				t1 = minf(t1, t)
			if t0 > t1:
				crosses = false
				break
	if crosses:
		return 0.0
	var best := minf(_point_box(la, h), _point_box(lb, h))
	for c in [Vector2(-h.x, -h.y), Vector2(h.x, -h.y), Vector2(h.x, h.y), Vector2(-h.x, h.y)]:
		best = minf(best, _point_segment(c, la, lb))
	return best


static func _point_box(q: Vector2, h: Vector2) -> float:
	var dx := maxf(absf(q.x) - h.x, 0.0)
	var dy := maxf(absf(q.y) - h.y, 0.0)
	return sqrt(dx * dx + dy * dy)


static func _point_segment(q: Vector2, a: Vector2, b: Vector2) -> float:
	return q.distance_to(Geometry2D.get_closest_point_to_segment(q, a, b))


func _cells(pos: Vector2, reach: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var lo := Vector2i(floori((pos.x - reach) / GRID_CELL), floori((pos.y - reach) / GRID_CELL))
	var hi := Vector2i(floori((pos.x + reach) / GRID_CELL), floori((pos.y + reach) / GRID_CELL))
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			out.append(Vector2i(x, y))
	return out


func _reserve(r: Dictionary) -> void:
	var idx := _rects.size()
	_rects.append(r)
	var reach: float = (r["size"] as Vector2).length() * 0.5
	for c in _cells(r["pos"], reach):
		if not _rect_grid.has(c):
			_rect_grid[c] = []
		_rect_grid[c].append(idx)


## True if `r` overlaps nothing placed and keeps `clearance` metres off the
## streets (plus each street's half width).
func _free(r: Dictionary, clearance: float) -> bool:
	var reach: float = (r["size"] as Vector2).length() * 0.5
	var seen := {}
	for c in _cells(r["pos"], reach):
		for idx: int in _rect_grid.get(c, []):
			if seen.has(idx):
				continue
			seen[idx] = true
			if _overlap(r, _rects[idx]):
				return false
	for c in _cells(r["pos"], reach + 6.0):
		for s: Array in _seg_grid.get(c, []):
			if _segment_rect_distance(s[0], s[1], r) < float(s[2]) + clearance:
				return false
	return true


## Distance from `p` to the nearest street other than `skip`, minus that
## street's half width.
func _street_gap(p: Vector2, skip: int) -> float:
	var best := INF
	for c in _cells(p, 20.0):
		for s: Array in _seg_grid.get(c, []):
			if s[3] == skip:
				continue
			best = minf(best, _point_segment(p, s[0], s[1]) - float(s[2]))
	return best


func _add_street(points: PackedVector2Array, kind: int) -> int:
	var idx := _streets.size()
	var hw: float = HALF_WIDTH[kind]
	_streets.append({"points": points, "half_width": hw, "kind": kind})
	for i in points.size() - 1:
		var a := points[i]
		var b := points[i + 1]
		var mid := (a + b) * 0.5
		for c in _cells(mid, a.distance_to(b) * 0.5 + hw):
			if not _seg_grid.has(c):
				_seg_grid[c] = []
			_seg_grid[c].append([a, b, hw, idx])
	return idx


## A wandering polyline from `start` heading `angle`.
func _walk(start: Vector2, angle: float, length: float, step: float, drift: float) -> PackedVector2Array:
	var pts := PackedVector2Array([start])
	var p := start
	var a := angle
	var turn := 0.0
	var done := 0.0
	while done < length:
		turn = turn * 0.6 + _rng.randf_range(-drift, drift)
		a += turn
		var s := minf(step, length - done)
		if s < 1.0:
			break
		p += Vector2.from_angle(a) * s
		pts.append(p)
		done += s
	return pts


static func _largest_gap_bisector(angles: Array[float]) -> float:
	var sorted: Array[float] = []
	for a in angles:
		sorted.append(fposmod(a, TAU))
	sorted.sort()
	var best := 0.0
	var best_mid := 0.0
	for i in sorted.size():
		var a := sorted[i]
		var b := sorted[(i + 1) % sorted.size()]
		var gap := fposmod(b - a, TAU)
		if gap == 0.0:
			gap = TAU
		if gap > best:
			best = gap
			best_mid = a + gap * 0.5
	return best_mid


## Where a ray from the square's centre at `angle` leaves the square.
static func _square_exit(square: Dictionary, angle: float) -> Vector2:
	var ax := _axes(square)
	var h: Vector2 = square["size"] * 0.5
	var d := Vector2.from_angle(angle)
	var lx := absf(d.dot(ax[0]))
	var ly := absf(d.dot(ax[1]))
	var t := minf(h.x / maxf(lx, 1e-6), h.y / maxf(ly, 1e-6))
	return (square["pos"] as Vector2) + d * t


func _sample(points: PackedVector2Array, t: float) -> Array:
	## [position, unit tangent] at arc length t.
	var left := t
	for i in points.size() - 1:
		var a := points[i]
		var b := points[i + 1]
		var len := a.distance_to(b)
		if left <= len or i == points.size() - 2:
			var dir := (b - a) / maxf(len, 1e-6)
			return [a + dir * clampf(left, 0.0, len), dir]
		left -= len
	return [points[0], Vector2.RIGHT]


static func _length(points: PackedVector2Array) -> float:
	var total := 0.0
	for i in points.size() - 1:
		total += points[i].distance_to(points[i + 1])
	return total


# --- streets ----------------------------------------------------------------

## The point of a street polyline at distance `r` from the town centre (or
## its end if it never gets that far).
func _at_radius(points: PackedVector2Array, r: float) -> Vector2:
	for i in points.size() - 1:
		var a := points[i]
		var b := points[i + 1]
		var ra := a.distance_to(_center)
		var rb := b.distance_to(_center)
		if ra <= r and rb >= r:
			return a.lerp(b, (r - ra) / maxf(rb - ra, 1e-6))
	return points[points.size() - 1]


## A bent street from main street `a` at radius `ra` to `b` at radius `rb`,
## bulging out through angle `mid`.
func _connect(a: PackedVector2Array, b: PackedVector2Array, ra: float, rb: float, mid: float) -> void:
	var p0 := _at_radius(a, ra)
	var p2 := _at_radius(b, rb)
	var bulge := (ra + rb) * 0.5 * _rng.randf_range(1.05, 1.35)
	var p1 := _center + Vector2.from_angle(mid) * bulge
	var length := p0.distance_to(p1) + p1.distance_to(p2)
	var steps := maxi(int(length / 20.0), 3)
	var pts := PackedVector2Array()
	var wobble := _rng.randf() * TAU
	for k in steps + 1:
		var t := float(k) / steps
		var q := p0.lerp(p1, t).lerp(p1.lerp(p2, t), t)
		if k > 0 and k < steps:
			var tangent := (p1.lerp(p2, t) - p0.lerp(p1, t)).normalized()
			q += Vector2(-tangent.y, tangent.x) * sin(t * 7.0 + wobble) * 6.0
		pts.append(q)
	_add_street(pts, Street.RING)


func _try_lane(square: Dictionary, plot: Dictionary) -> bool:
	# Pick a parent street weighted by its length inside the town.
	var total := 0.0
	var lengths: Array[float] = []
	for s in _streets:
		var l := 0.0 if s["kind"] == Street.ROAD else _length(s["points"])
		lengths.append(l)
		total += l
	var pick := _rng.randf() * total
	var parent := 0
	for i in lengths.size():
		pick -= lengths[i]
		if pick <= 0.0:
			parent = i
			break
	var pts: PackedVector2Array = _streets[parent]["points"]
	var at := _sample(pts, _rng.randf() * _length(pts))
	var p: Vector2 = at[0]
	var u := p.distance_to(_center) / _radius
	if u < 0.12 or u > 0.92:
		return false
	var side := 1.0 if _rng.randf() < 0.5 else -1.0
	var dir: Vector2 = at[1]
	var angle := dir.angle() + side * PI * 0.5 + _rng.randf_range(-0.35, 0.35)
	var length := _rng.randf_range(50.0, 90.0 + _radius * 0.3)
	var raw := _walk(p, angle, length, 14.0, 0.12)
	var hw: float = HALF_WIDTH[Street.LANE]
	var out := PackedVector2Array([raw[0]])
	for i in range(1, raw.size()):
		var q := raw[i]
		if q.distance_to(_center) > _radius * 1.02:
			break
		var probe := _rect(q, 0.0, Vector2(4, 4))
		if _overlap(probe, square) or _overlap(probe, plot):
			break
		var gap := _street_gap(q, parent)
		if i >= 2 and gap < hw + 30.0:
			# Close to another street: join it and stop, closing a block.
			if gap < hw + 30.0 and gap > 0.0:
				out.append(q)
			break
		if i < 2 and gap < hw + 18.0:
			return false
		out.append(q)
	if out.size() < 3 or _length(out) < 40.0:
		return false
	_add_street(out, Street.LANE)
	return true


# --- buildings ---------------------------------------------------------------

func _add_church(square: Dictionary, big: bool) -> void:
	var ax := _axes(square)
	var sq: Vector2 = square["size"]
	var nave := Vector2(24.0, 12.0) if big else Vector2(17.0, 9.0)
	var tower := 7.0 if big else 5.5
	# Nave along the square's long axis, towards one end; tower at its west end.
	var along := sq.x * 0.5 - nave.x * 0.5 - 8.0
	var nave_pos: Vector2 = (square["pos"] as Vector2) + ax[0] * (along - sq.x * 0.12)
	var tower_pos := nave_pos - ax[0] * (nave.x * 0.5 + tower * 0.5 - 0.5)
	var angle: float = square["angle"]
	var b := _rect(nave_pos, angle, nave)
	b.merge({"kind": Kind.CHURCH, "floors": 1, "wall_height": 9.0 if big else 7.0,
			"roof": Roof.GABLE, "pitch": deg_to_rad(52.0), "ridge_x": true,
			"wall": 0, "roof_colour": 3})
	_buildings.append(b)
	var t := _rect(tower_pos, angle, Vector2(tower, tower))
	t.merge({"kind": Kind.CHURCH, "floors": 1, "wall_height": 30.0 if big else 22.0,
			"roof": Roof.HIP, "pitch": deg_to_rad(78.0), "ridge_x": true,
			"wall": 0, "roof_colour": -1})
	_buildings.append(t)


## Picks a building for a lot at relative distance `u` from the centre.
## Returns {} for an empty lot.
func _archetype(u: float, street_kind: int) -> Dictionary:
	var dens := clampf(_pop / 5000.0, 0.1, 1.5)
	var r := _rng.randf()
	var b := {}
	var apart_limit := 0.28 + 0.14 * dens if _pop >= 1800 else -1.0
	if street_kind == Street.LANE:
		apart_limit *= 0.7
	var row_limit := 0.58 if _pop >= 1500 else 0.36
	if u < apart_limit:
		var floors: int = 3 + (1 if _rng.randf() < dens * 0.7 else 0) if _pop >= 3200 else 2 + (1 if r < 0.6 else 0)
		b = {"kind": Kind.APARTMENT, "w": _rng.randf_range(13.0, 24.0), "d": _rng.randf_range(11.0, 14.0),
				"floors": floors, "floor_h": 3.1, "gap": 0.0 if _rng.randf() < 0.85 else _rng.randf_range(2.0, 5.0),
				"setback": 0.0, "roof": Roof.HIP if _rng.randf() < 0.45 else Roof.GABLE,
				"pitch": _rng.randf_range(30.0, 42.0), "ridge_x": true}
	elif u < row_limit:
		b = {"kind": Kind.ROW, "w": _rng.randf_range(7.0, 10.5), "d": _rng.randf_range(9.0, 11.5),
				"floors": 2 if (_pop >= 1500 or r < 0.5) else 1, "floor_h": 3.0,
				"gap": 0.0 if _rng.randf() < 0.7 else _rng.randf_range(2.0, 6.0),
				"setback": _rng.randf_range(0.0, 1.5), "roof": Roof.GABLE,
				"pitch": _rng.randf_range(38.0, 50.0), "ridge_x": _rng.randf() < 0.85}
	elif u < 1.02:
		var edge := u > 0.78
		if edge and r < 0.12:
			return {}
		if edge and r < 0.36:
			var barn := _rng.randf() < 0.55
			b = {"kind": Kind.BARN if barn else Kind.WORKSHOP, "w": _rng.randf_range(14.0, 24.0),
					"d": _rng.randf_range(9.0, 14.0), "floors": 1,
					"floor_h": _rng.randf_range(4.5, 6.5), "gap": _rng.randf_range(8.0, 18.0),
					"setback": _rng.randf_range(4.0, 10.0), "roof": Roof.GABLE,
					"pitch": _rng.randf_range(24.0, 36.0), "ridge_x": true}
		else:
			if r > 0.93:
				return {}
			b = {"kind": Kind.HOUSE, "w": _rng.randf_range(8.0, 11.5), "d": _rng.randf_range(8.0, 10.5),
					"floors": 2 if _rng.randf() < 0.45 else 1, "floor_h": 2.9,
					"gap": _rng.randf_range(7.0, 15.0) + (5.0 if _pop < 1000 else 0.0),
					"setback": _rng.randf_range(3.5, 8.0),
					"roof": Roof.HIP if _rng.randf() < 0.15 else Roof.GABLE,
					"pitch": _rng.randf_range(38.0, 50.0), "ridge_x": _rng.randf() < 0.55}
	else:
		if r < 0.1 and u < 1.35:
			b = {"kind": Kind.BARN, "w": _rng.randf_range(16.0, 26.0), "d": _rng.randf_range(10.0, 14.0),
					"floors": 1, "floor_h": _rng.randf_range(5.0, 7.0), "gap": 40.0,
					"setback": _rng.randf_range(6.0, 14.0), "roof": Roof.GABLE,
					"pitch": _rng.randf_range(24.0, 34.0), "ridge_x": true}
		else:
			return {}
	return b


func _colours_for(kind: int) -> Vector2i:
	## (wall, roof) palette indices. Wall indices >= WALL_COLOURS are brick
	## (WALL_COLOURS) and timber (WALL_COLOURS + 1). Roofs are mostly clay
	## tiles, some slate.
	var wall := _rng.randi_range(0, WALL_COLOURS - 1)
	var roof := _pick([0.34, 0.24, 0.14, 0.1, 0.18])
	match kind:
		Kind.BARN:
			wall = WALL_COLOURS + 1 if _rng.randf() < 0.6 else wall
			roof = 2 if _rng.randf() < 0.5 else roof
		Kind.WORKSHOP:
			wall = WALL_COLOURS if _rng.randf() < 0.7 else wall
		Kind.APARTMENT, Kind.HALL:
			roof = 3 if _rng.randf() < 0.2 else roof
	return Vector2i(wall, roof)


func _pick(weights: Array[float]) -> int:
	var r := _rng.randf()
	for i in weights.size():
		r -= weights[i]
		if r <= 0.0:
			return i
	return weights.size() - 1


## Tries to put building `arch` with its front on the line through `p` with
## unit tangent `tangent`; `side` picks the side, `front` is the distance
## from the line to the facade. Adds a back yard where it fits.
func _place(arch: Dictionary, p: Vector2, tangent: Vector2, side: float, front: float) -> bool:
	var w: float = arch["w"]
	var d: float = arch["d"]
	var angle := tangent.angle() + (0.0 if side > 0.0 else PI)
	var ax := [Vector2(cos(angle), sin(angle)), Vector2(-sin(angle), cos(angle))]
	var pos: Vector2 = p + (ax[1] as Vector2) * (front + d * 0.5)
	var test := _rect(pos, angle, Vector2(w - 0.6, d - 0.6))
	if not _free(test, 0.6):
		return false
	var cols := _colours_for(arch["kind"])
	var b := _rect(pos, angle, Vector2(w, d))
	b.merge({"kind": arch["kind"], "floors": arch["floors"],
			"wall_height": float(arch["floors"]) * float(arch["floor_h"]),
			"roof": arch["roof"], "pitch": deg_to_rad(arch["pitch"]),
			"ridge_x": arch["ridge_x"], "wall": cols.x, "roof_colour": cols.y})
	_buildings.append(b)
	_reserve(test)
	var kind: int = arch["kind"]
	var wing_chance := {Kind.APARTMENT: 0.6, Kind.HALL: 1.0, Kind.ROW: 0.35, Kind.HOUSE: 0.12}
	if _rng.randf() < float(wing_chance.get(kind, 0.0)):
		# Rear wing: an L-shaped plot like the old town houses.
		var ww := _rng.randf_range(5.5, 8.0)
		var wd := _rng.randf_range(7.0, 14.0)
		var end := 1.0 if _rng.randf() < 0.5 else -1.0
		# Tucked 0.2 m into the main building so no gap shows.
		var wpos: Vector2 = pos + (ax[0] as Vector2) * end * (w - ww) * 0.5 + (ax[1] as Vector2) * ((d + wd) * 0.5 - 0.2)
		var wtest := _rect(wpos, angle, Vector2(ww - 0.6, wd - 0.6))
		if _free(wtest, 0.6):
			var floors := maxi(int(arch["floors"]) - 1, 1)
			var wing := _rect(wpos, angle, Vector2(ww, wd))
			wing.merge({"kind": kind, "floors": floors,
					"wall_height": floors * float(arch["floor_h"]), "roof": Roof.GABLE,
					"pitch": deg_to_rad(arch["pitch"]), "ridge_x": false,
					"wall": cols.x, "roof_colour": cols.y, "wing": true})
			_buildings.append(wing)
			_reserve(wtest)
	if arch["kind"] in [Kind.HOUSE, Kind.ROW, Kind.BARN] or (arch["kind"] == Kind.APARTMENT and _rng.randf() < 0.3):
		var lot_w := w + minf(float(arch["gap"]), 10.0) * 0.8
		for depth: float in [_rng.randf_range(12.0, 26.0), 9.0]:
			var ypos: Vector2 = pos + (ax[1] as Vector2) * (d * 0.5 + 0.8 + depth * 0.5)
			var yard := _rect(ypos, angle, Vector2(lot_w, depth))
			if _free(yard, 0.8):
				yard["colour"] = _rng.randi_range(0, YARD_COLOURS - 1)
				_yards.append(yard)
				_reserve(yard)
				break
	return true


func _front_street(idx: int, side: float) -> void:
	var s := _streets[idx]
	var pts: PackedVector2Array = s["points"]
	var kind: int = s["kind"]
	var hw: float = s["half_width"]
	var total := _length(pts)
	var t := hw + 2.0 if kind == Street.LANE else 0.0
	while t < total - 4.0:
		var at := _sample(pts, t)
		var u := (at[0] as Vector2).distance_to(_center) / _radius
		if kind != Street.ROAD and u > (1.0 if _pop < 1000 else 1.08):
			break
		if kind == Street.ROAD and u > 1.4:
			break
		var arch := _archetype(u, kind)
		if arch.is_empty():
			t += _rng.randf_range(10.0, 25.0)
			continue
		var w: float = arch["w"]
		var mid := _sample(pts, t + w * 0.5)
		var front := hw + SIDEWALK + float(arch["setback"])
		if _place(arch, mid[0], mid[1], side, front):
			t += w + float(arch["gap"])
		else:
			t += 3.0


func _front_square(square: Dictionary, big: bool) -> void:
	var c := corners(square)
	for e in 4:
		var a := c[e]
		var b := c[(e + 1) % 4]
		var tangent := (b - a).normalized()
		# Corners run counter-clockwise, so the outside is to the right.
		var outward := Vector2(tangent.y, -tangent.x)
		var side := 1.0 if Vector2(-tangent.y, tangent.x).dot(outward) > 0.0 else -1.0
		var len := a.distance_to(b)
		var t := 0.0
		var hall := big and e == 2
		while t < len + 6.0:
			var arch: Dictionary
			if hall:
				arch = {"kind": Kind.HALL, "w": 26.0, "d": 15.0, "floors": 3, "floor_h": 3.4,
						"gap": 0.0, "setback": 0.0, "roof": Roof.HIP, "pitch": 38.0, "ridge_x": true}
				hall = false
				t = len * 0.5 - 13.0
			elif _pop >= 1800:
				arch = _archetype(0.0, Street.MAIN)
			else:
				arch = _archetype(0.3, Street.MAIN)
			if arch.is_empty():
				t += 6.0
				continue
			var w: float = arch["w"]
			var p := a + tangent * (t - 3.0 + w * 0.5)
			if _place(arch, p, tangent, side, 1.0):
				t += w + float(arch["gap"])
			else:
				t += 3.0


# --- fields ------------------------------------------------------------------

## Fields between `r_in` and (roughly) `r_out`: every sector between two
## main streets gets its own grid of field blocks, turned its own way, so the
## fields form a patchwork rather than rings.
func _add_fields(r_in: float, r_out: float, angles: Array[float]) -> void:
	var sorted: Array[float] = []
	for a in angles:
		sorted.append(fposmod(a, TAU))
	sorted.sort()
	var phase := _rng.randf() * TAU
	for k in sorted.size():
		var a0 := sorted[k]
		var span := fposmod(sorted[(k + 1) % sorted.size()] - a0, TAU)
		if span == 0.0:
			span = TAU
		var grid_angle := a0 + span * 0.5 + _rng.randf_range(-0.4, 0.4)
		var gx := Vector2.from_angle(grid_angle)
		var gy := Vector2(-gx.y, gx.x)
		var cell := Vector2(_rng.randf_range(110.0, 170.0), _rng.randf_range(80.0, 130.0))
		var n := int(r_out * 1.2 / minf(cell.x, cell.y)) + 1
		for i in range(-n, n + 1):
			for j in range(-n, n + 1):
				var c := _center + gx * (i * cell.x) + gy * (j * cell.y)
				var rel := c - _center
				var r := rel.length()
				var th := fposmod(rel.angle() - a0, TAU)
				if th > span:
					continue
				var edge := r_out * (0.85 + 0.15 * sin(3.0 * rel.angle() + phase)
						+ 0.08 * sin(7.0 * rel.angle() + phase * 2.0))
				if r < r_in or r > edge or _rng.randf() < 0.05:
					continue
				var jitter := Vector2(_rng.randf_range(-6.0, 6.0), _rng.randf_range(-6.0, 6.0))
				var block := _rect(c + jitter, grid_angle,
						cell - Vector2(_rng.randf_range(4.0, 9.0), _rng.randf_range(4.0, 9.0)))
				_split_block(block)


## Splits a field block into 1 to 5 parallel strips of different crops.
func _split_block(block: Dictionary) -> void:
	var size: Vector2 = block["size"]
	var ax := _axes(block)
	var along_x := _rng.randf() < 0.5
	var span := size.y if along_x else size.x
	var n := _rng.randi_range(1, 5)
	var cuts: Array[float] = [0.0]
	for i in n - 1:
		cuts.append(_rng.randf_range(0.1, 0.9))
	cuts.append(1.0)
	cuts.sort()
	var colour := _rng.randi_range(0, FIELD_COLOURS - 1)
	for i in n:
		var w := (cuts[i + 1] - cuts[i]) * span - 2.0
		if w < 10.0:
			continue
		var off := ((cuts[i] + cuts[i + 1]) * 0.5 - 0.5) * span
		var pos: Vector2 = block["pos"]
		var f: Dictionary
		if along_x:
			f = _rect(pos + ax[1] * off, block["angle"], Vector2(size.x, w))
		else:
			f = _rect(pos + ax[0] * off, block["angle"], Vector2(w, size.y))
		if not _free(f, 4.0):
			continue
		# Neighbouring strips rarely share a crop.
		colour = (colour + _rng.randi_range(1, FIELD_COLOURS - 1)) % FIELD_COLOURS
		f["colour"] = colour
		_fields.append(f)
		_reserve(f)
