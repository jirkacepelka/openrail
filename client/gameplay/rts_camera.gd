extends Camera3D
## RTS style camera: WASD / screen edge pan, mouse wheel zoom, middle-drag
## (or Q/E) rotate. Attach to the existing Camera3D. The initial pose is
## derived from the node's transform in the scene until `jump_to` is called.
## With a `sim` the focus rides on the terrain and the camera never dips
## below the ground.

const MIN_PITCH := 0.26 # about 15 degrees
const MAX_PITCH := 1.48 # about 85 degrees
const Ground := preload("res://world/ground.gd")

@export var pan_speed := 1.2 ## Pan speed in "distances per second".
@export var fast_multiplier := 3.0 ## Held Shift multiplies pan speed.
@export var edge_pan := true
@export var edge_margin := 8.0 ## Pixels from the window border.
@export var zoom_step := 0.88 ## Distance factor per wheel notch.
@export var min_distance := 50.0
@export var max_distance := 8000.0
## Metres the camera keeps above the ground (grows with the distance).
@export var ground_clearance := 12.0
@export var rotate_sensitivity := 0.005
@export var key_rotate_speed := 1.6 ## Radians per second for Q / E.
@export var smoothing := 12.0

## World whose terrain the camera follows (null: flat ground at y = 0).
var sim: SimWorld

var focus := Vector3.ZERO
var yaw := 0.0
var pitch := 0.78
var distance := 2000.0

var _target_focus := Vector3.ZERO
var _target_yaw := 0.0
var _target_pitch := 0.0
var _target_distance := 0.0


func _ready() -> void:
	# Derive the initial rig state from the scene transform: the focus is
	# where the view axis meets the ground plane.
	var origin := global_position
	var forward := -global_transform.basis.z
	if forward.y < -0.05:
		distance = -origin.y / forward.y
		focus = origin + forward * distance
		pitch = asin(clampf(-forward.y, 0.0, 1.0))
		yaw = atan2(-forward.x, -forward.z)
	distance = clampf(distance, min_distance, max_distance)
	pitch = clampf(pitch, MIN_PITCH, MAX_PITCH)
	_target_focus = focus
	_target_yaw = yaw
	_target_pitch = pitch
	_target_distance = distance
	_apply()


## Smoothly move the view so that `world_point` is at the centre.
func focus_on(world_point: Vector3) -> void:
	_target_focus = Vector3(world_point.x, 0.0, world_point.z)


## Moves the view at once: look at `world_point` (only x and z count) from
## `p_distance` metres, `p_pitch` radians above the horizon, facing `p_yaw`.
func jump_to(world_point: Vector3, p_yaw: float, p_pitch: float, p_distance: float) -> void:
	focus = Vector3(world_point.x, _ground(world_point.x, world_point.z), world_point.z)
	yaw = p_yaw
	pitch = clampf(p_pitch, MIN_PITCH, MAX_PITCH)
	distance = clampf(p_distance, min_distance, max_distance)
	_target_focus = focus
	_target_yaw = yaw
	_target_pitch = pitch
	_target_distance = distance
	_apply()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_target_distance = clampf(_target_distance * zoom_step, min_distance, max_distance)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_target_distance = clampf(_target_distance / zoom_step, min_distance, max_distance)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			_target_yaw -= mm.relative.x * rotate_sensitivity
			_target_pitch = clampf(
				_target_pitch + mm.relative.y * rotate_sensitivity, MIN_PITCH, MAX_PITCH
			)


func _process(delta: float) -> void:
	var move := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		move.y += 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		move.y -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		move.x += 1.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		move.x -= 1.0
	if move == Vector2.ZERO and edge_pan:
		move = _edge_direction()

	if Input.is_physical_key_pressed(KEY_Q):
		_target_yaw += key_rotate_speed * delta
	if Input.is_physical_key_pressed(KEY_E):
		_target_yaw -= key_rotate_speed * delta

	if move != Vector2.ZERO:
		var speed := pan_speed * _target_distance
		if Input.is_physical_key_pressed(KEY_SHIFT):
			speed *= fast_multiplier
		var fwd := Vector3(-sin(_target_yaw), 0.0, -cos(_target_yaw))
		var right := Vector3(cos(_target_yaw), 0.0, -sin(_target_yaw))
		_target_focus += (right * move.x + fwd * move.y).normalized() * speed * delta
		_target_focus.x = clampf(_target_focus.x, -50000.0, 50000.0)
		_target_focus.z = clampf(_target_focus.z, -50000.0, 50000.0)

	var t := 1.0 - exp(-smoothing * delta)
	_target_focus.y = _ground(_target_focus.x, _target_focus.z)
	focus = focus.lerp(_target_focus, t)
	yaw = lerp_angle(yaw, _target_yaw, t)
	pitch = lerpf(pitch, _target_pitch, t)
	distance = lerpf(distance, _target_distance, t)
	_apply()


func _edge_direction() -> Vector2:
	if not edge_pan or not get_window().has_focus():
		return Vector2.ZERO
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		return Vector2.ZERO
	var vp := get_viewport()
	# Do not scroll while the pointer is on UI such as the bottom toolbar.
	if vp.gui_get_hovered_control() != null:
		return Vector2.ZERO
	var rect := vp.get_visible_rect()
	var m := vp.get_mouse_position()
	if not rect.has_point(m):
		return Vector2.ZERO
	var dir := Vector2.ZERO
	if m.x < edge_margin:
		dir.x -= 1.0
	elif m.x > rect.size.x - edge_margin:
		dir.x += 1.0
	if m.y < edge_margin:
		dir.y += 1.0
	elif m.y > rect.size.y - edge_margin:
		dir.y -= 1.0
	return dir


func _ground(x: float, z: float) -> float:
	return Ground.height_at(sim, x, z) if sim != null else 0.0


func _apply() -> void:
	var offset := Vector3(
		sin(yaw) * cos(pitch),
		sin(pitch),
		cos(yaw) * cos(pitch),
	) * distance
	var pos := focus + offset
	# Stay above hills between the camera and the focus.
	var floor_y := _ground(pos.x, pos.z) + ground_clearance + distance * 0.02
	pos.y = maxf(pos.y, floor_y)
	# Near plane scaled to the zoom for fine depth close up. The far plane
	# only ever grows (ArtStyle may have set it further for its fog).
	near = clampf(distance * 0.002, 0.25, 20.0)
	far = maxf(far, 40000.0)
	look_at_from_position(pos, focus, Vector3.UP)
