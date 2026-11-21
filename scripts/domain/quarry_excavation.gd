extends "res://scripts/domain/quarry_slopes.gd"
## Rectangular cuts are planned from the shallowest exposed span. One
## staircase on the near face connects the working levels across the cut.

const ScaffoldRoad = preload("res://scripts/domain/scaffold_road.gd")
const BAY_SIZE := 4
const TUNNEL_ROOF_DEPTH := 2

var _unit: Vector2
var _columns: int
var _surface_columns: int
var _left: float
var _right: float
var _cuts: Array[Rect2i] = []
var _landings := PackedVector2Array()
var _depths: PackedInt32Array
var _mined := 0
var _planned_depth := 0
var _original_left: float
var _original_end: float
var _framing_depths := PackedInt32Array([0])
var _original_planned_depth: int


func _init(world: Dictionary, unit: Vector2, width: float, sizes: Array[int],
		planned_count: int, target_width: float) -> void:
	super(world)
	_unit = unit
	var bays := maxi(3, roundi(width / (BAY_SIZE * unit.x)))
	var original_columns := bays * BAY_SIZE
	var extra_columns := int(world.get("quarryExtraBays", 0)) * BAY_SIZE
	_surface_columns = original_columns + extra_columns
	var tunnel_limit := int(world.get("quarryUndergroundBays", 0)) * BAY_SIZE
	_columns = _surface_columns + tunnel_limit
	_right = _mouth.x + original_columns * unit.x * 0.5
	_left = _right - _surface_columns * unit.x
	_original_left = _left
	_original_end = _x(_columns)
	_mouth.x = (_left + _right) * 0.5

	var original_cuts := _plan_cuts(sizes, _columns)
	for cells in original_cuts:
		_framing_depths.append(maxi(_framing_depths[-1], cells.end.y))
	_original_planned_depth = _cut_depth(original_cuts, planned_count)

	# Leave room for an exposed four-cell span, a pair and one small cut
	# when the blueprint needs all three sizes.
	var minimum := 1
	if sizes.has(BAY_SIZE):
		minimum = BAY_SIZE + (3 if sizes.has(2) else 1)
	elif sizes.has(2):
		minimum = 3
	_columns = maxi(minimum, roundi(target_width / _unit.x))
	var tunnel_columns := mini(tunnel_limit, floori(_columns * 0.5))
	_surface_columns = maxi(minimum, _columns - tunnel_columns)
	_left = _right - _surface_columns * _unit.x
	_cuts = _plan_cuts(sizes, _columns)
	_depths.resize(_columns)
	_planned_depth = _cut_depth(_cuts, planned_count)

	_landings.append(Vector2(_right, _mouth.y))
	for depth in range(1, _cut_depth(_cuts, _cuts.size()) + 1):
		var direction := -1.0 if (((depth - 1) >> 1) & 1) == 0 else 1.0
		var flight := ScaffoldRoad.flight_points(_landings[-1], _y(depth), 1, _unit.x * 0.8, 0.0, direction)
		_landings.append(flight[0])


func _plan_cuts(sizes: Array[int], columns: int) -> Array[Rect2i]:
	var cuts: Array[Rect2i] = []
	var profile := PackedInt32Array()
	profile.resize(columns)
	_set_span(profile, _surface_columns, columns - _surface_columns, TUNNEL_ROOF_DEPTH)
	var wide_left := sizes.count(BAY_SIZE)
	var pairs_left := sizes.count(2)
	for size in sizes:
		wide_left -= int(size == BAY_SIZE)
		pairs_left -= int(size == 2)
		var column := _next_span(profile, size, wide_left > 0, pairs_left > 0)
		var depth := profile[column]
		cuts.append(Rect2i(column, depth, size, size))
		_set_span(profile, column, size, depth + size)
	return cuts


func _cut_depth(cuts: Array[Rect2i], count: int) -> int:
	var deepest := 0
	for id in range(mini(count, cuts.size())):
		deepest = maxi(deepest, cuts[id].end.y)
	return deepest


func _next_span(profile: PackedInt32Array, size: int, need_wide: bool, need_pair: bool) -> int:
	var best := -1
	var best_depth := 2147483647
	var best_connected := false
	for column in range(profile.size() - size, -1, -1):
		var depth := profile[column]
		if depth > best_depth or not _is_flat(profile, column, size):
			continue
		if column < _surface_columns and column + size > _surface_columns:
			continue
		if column >= _surface_columns and not _tunnel_reaches(profile, column, depth + size):
			continue
		var connected := (column > 0 and profile[column - 1] > depth) \
			or (column + size < profile.size() and profile[column + size] > depth)
		if depth == best_depth and (best_connected or not connected):
			continue
		_set_span(profile, column, size, depth + size)
		var has_room := _has_room_for_mixed_sizes(profile, need_wide, need_pair)
		_set_span(profile, column, size, depth)
		if has_room:
			best = column
			best_depth = depth
			best_connected = connected
	return best


func _tunnel_reaches(profile: PackedInt32Array, column: int, floor_depth: int) -> bool:
	# A loaded sled needs a clear approach at the new floor all the way
	# from the shared stair to the stone under the roof.
	for corridor in range(maxi(0, _surface_columns - 2), column):
		if profile[corridor] < floor_depth:
			return false
	return true


func _has_room_for_mixed_sizes(profile: PackedInt32Array, need_wide: bool, need_pair: bool) -> bool:
	if not need_wide and not need_pair:
		return true
	# Keep a flat four-cell span and a separate flat pair somewhere on the
	# profile. Their locations can change every strike as the cut develops.
	var wide := 0
	var remainder := _surface_columns % BAY_SIZE
	var separate_pair := remainder >= 2 and _is_flat(profile, _surface_columns - remainder, 2)
	for column in range(0, _surface_columns - remainder, BAY_SIZE):
		if _is_flat(profile, column, BAY_SIZE):
			wide += 1
		elif _is_flat(profile, column, 2) or _is_flat(profile, column + 2, 2):
			separate_pair = true
	if not need_wide:
		return wide > 0 or separate_pair
	return wide > 0 and (not need_pair or wide >= 2 or separate_pair)


func _is_flat(profile: PackedInt32Array, column: int, size: int) -> bool:
	for index in range(column + 1, column + size):
		if profile[index] != profile[column]:
			return false
	return true


func _set_span(profile: PackedInt32Array, column: int, size: int, depth: int) -> void:
	for index in range(column, column + size):
		profile[index] = depth


func mouth() -> Vector2:
	return _mouth


func framing_bounds(mined: int = 0) -> Rect2:
	var depth := maxi(_original_planned_depth, _framing_depths[mini(mined, _framing_depths.size() - 1)])
	var height := depth * _unit.y
	return Rect2(_original_left, _mouth.y - height, _original_end - _original_left, height)


func bounds(mined: int = 0) -> Rect2:
	_update_depths(mined)
	var depth := _planned_depth
	for opened_depth in _depths:
		depth = maxi(depth, opened_depth)
	var height := depth * _unit.y
	return Rect2(_left, _mouth.y - height, _columns * _unit.x, height)


func cut(resource_id: int) -> Rect2:
	var cells := _cuts[resource_id]
	return Rect2(_x(cells.position.x), _y(cells.end.y), cells.size.x * _unit.x, cells.size.y * _unit.y)


func work_position(resource_id: int) -> Vector2:
	var block := cut(resource_id)
	return Vector2(block.position.x + block.size.x * 0.08, _y(_cuts[resource_id].position.y))


func pickup_position(resource_id: int) -> Vector2:
	var block := cut(resource_id)
	return Vector2(block.get_center().x, block.position.y)


func outline(mined: int) -> PackedVector2Array:
	_update_depths(mined)
	if mined == 0:
		return PackedVector2Array()
	var points := PackedVector2Array()
	var previous := 0
	for column in range(_surface_columns + 1):
		var depth := _depths[column] if column < _surface_columns else 0
		if depth != previous:
			points.append(Vector2(_x(column), _y(previous)))
			points.append(Vector2(_x(column), _y(depth)))
			previous = depth
	return points


func tunnel_outline(mined: int) -> PackedVector2Array:
	_update_depths(mined)
	var points := PackedVector2Array()
	if _columns == _surface_columns or _depths[_surface_columns] <= TUNNEL_ROOF_DEPTH:
		return points
	var previous := _depths[_surface_columns]
	points.append(Vector2(_right, _y(TUNNEL_ROOF_DEPTH)))
	points.append(Vector2(_right, _y(previous)))
	for column in range(_surface_columns + 1, _columns + 1):
		var depth := maxi(TUNNEL_ROOF_DEPTH, _depths[column]) if column < _columns else TUNNEL_ROOF_DEPTH
		if depth != previous:
			points.append(Vector2(_x(column), _y(previous)))
			points.append(Vector2(_x(column), _y(depth)))
			previous = depth
		if depth == TUNNEL_ROOF_DEPTH:
			break
	return points


func scaffold_paths(mined: int) -> Array[PackedVector2Array]:
	var paths: Array[PackedVector2Array] = []
	if mined == 0:
		return paths
	_update_depths(mined)
	var deepest := 0
	for depth in _depths:
		deepest = maxi(deepest, depth)
	paths.append(_landings.slice(0, deepest + 1))

	var floor_left := PackedFloat32Array()
	floor_left.resize(deepest + 1)
	var floor_right := PackedFloat32Array()
	floor_right.resize(deepest + 1)
	for depth in range(deepest + 1):
		floor_left[depth] = _landings[depth].x
		floor_right[depth] = _landings[depth].x
	for id in range(mini(mined + 1, _cuts.size())):
		var cells := _cuts[id]
		if id < mined:
			floor_left[0] = minf(floor_left[0], _x(cells.position.x))
			var pickup := pickup_position(id)
			var depth := cells.end.y
			floor_left[depth] = minf(floor_left[depth], pickup.x)
			floor_right[depth] = maxf(floor_right[depth], pickup.x)
		if cells.position.y > 0:
			var work := work_position(id)
			var depth := cells.position.y
			floor_left[depth] = minf(floor_left[depth], work.x)
			floor_right[depth] = maxf(floor_right[depth], work.x)
	for depth in range(deepest + 1):
		if floor_left[depth] < floor_right[depth]:
			var y := _landings[depth].y
			paths.append(ScaffoldRoad.deck_path(Vector2(floor_left[depth], y), Vector2(floor_right[depth], y)))
	return paths


func terrain_y(x: float) -> float:
	var column := floori((x - _left) / _unit.x)
	return _y(_depths[column]) if column >= 0 and column < _columns else _mouth.y


func point(x: float, _mined_count: int) -> Vector2:
	return Vector2(x, _mouth.y)


func project(position: Vector2, _mined_count: int) -> Vector2:
	return Vector2(position.x, _mouth.y) if position.x <= _right else position


func surface_y(x: float, _mined_count: int, storage: Vector2) -> float:
	if x <= _right:
		return _mouth.y
	return lerpf(_mouth.y, storage.y, clampf(inverse_lerp(_right, storage.x, x), 0.0, 1.0))


func route(start: Vector2, finish: Vector2, _mined_count: int) -> PackedVector2Array:
	if start == finish:
		return PackedVector2Array([start])
	var starts_outside := _on_storage_approach(start)
	var ends_outside := _on_storage_approach(finish)
	if starts_outside and ends_outside:
		return ScaffoldRoad.deck_path(start, finish)
	var from_level := _level_at(start)
	var to_level := _level_at(finish)
	var points := PackedVector2Array([start])
	if from_level != to_level:
		var step := 1 if from_level < to_level else -1
		for level in range(from_level, to_level + step, step):
			_append_distinct(points, _landings[level])
	elif starts_outside or ends_outside:
		_append_distinct(points, _landings[0])
	_append_distinct(points, finish)
	return points


func _on_storage_approach(point_on_route: Vector2) -> bool:
	return point_on_route.x > _right and point_on_route.y >= _mouth.y


func _level_at(point_on_route: Vector2) -> int:
	return clampi(roundi((_mouth.y - point_on_route.y) / _unit.y), 0, _landings.size() - 1)


func _append_distinct(points: PackedVector2Array, point_on_route: Vector2) -> void:
	if points[-1] != point_on_route:
		points.append(point_on_route)


func _update_depths(mined: int) -> void:
	if mined < _mined:
		_depths.fill(0)
		_mined = 0
	while _mined < mined:
		var cells := _cuts[_mined]
		for column in range(cells.position.x, cells.end.x):
			_depths[column] = cells.end.y
		_mined += 1


func _x(column: int) -> float:
	return _left + column * _unit.x


func _y(depth: int) -> float:
	return _mouth.y - depth * _unit.y
