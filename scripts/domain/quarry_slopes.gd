extends RefCounted
## The outline and all quarry walking routes use the same surface.

var _mouth: Vector2
var _step: Vector2
var _right_exit: Vector2


func _init(world: Dictionary) -> void:
	_mouth = Vector2(world.quarryCenterX, -world.terraceDrop)
	_step = Vector2(world.quarryStepX, world.quarryLayerHeight)
	_right_exit = _mouth + Vector2((float(world.quarryLayers) - 0.5) * _step.x, 0)


func outline(mined: int) -> PackedVector2Array:
	if mined == 0:
		return PackedVector2Array()
	var scale_factor := sqrt(float(mined))
	var half_width := (scale_factor - 0.5) * _step.x
	return PackedVector2Array([
		_mouth - Vector2(half_width, 0),
		_mouth - Vector2(0, scale_factor * _step.y),
		_mouth + Vector2(half_width, 0),
	])


func point(x: float, mined: int) -> Vector2:
	var scale_factor := sqrt(float(mined))
	var half_width := (scale_factor - 0.5) * _step.x
	var depth := 0.0
	if half_width > 0.0:
		depth = maxf(0.0, 1.0 - absf(x - _mouth.x) / half_width) * scale_factor * _step.y
	return Vector2(x, _mouth.y - depth)


func project(point_before: Vector2, mined: int) -> Vector2:
	return point(point_before.x, mined) if point_before.x <= _right_exit.x else point_before


func surface_y(x: float, mined: int, storage: Vector2) -> float:
	if x <= _right_exit.x:
		return point(x, mined).y
	var progress := clampf(inverse_lerp(_right_exit.x, storage.x, x), 0.0, 1.0)
	return lerpf(_right_exit.y, storage.y, progress)


func route(start: Vector2, finish: Vector2, mined: int) -> PackedVector2Array:
	var reversed := start.x > finish.x
	var left := finish if reversed else start
	var right := start if reversed else finish
	var points := PackedVector2Array([left])
	for corner in outline(mined):
		if left.x < corner.x and corner.x < right.x:
			points.append(corner)
	if right.y > _mouth.y and left.x < _right_exit.x and _right_exit.x < right.x:
		if points[-1] != _right_exit:
			points.append(_right_exit)
	if points[-1] != right:
		points.append(right)
	if reversed:
		points.reverse()
	return points
