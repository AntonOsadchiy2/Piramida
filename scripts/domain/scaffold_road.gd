extends RefCounted
## Each floor serves two vertical cells of masonry. A new floor branches off
## the first work point of the previous row.

var paths: Array[PackedVector2Array] = []
var _points := PackedVector2Array()
var _parents := PackedInt32Array()
var _work_nodes: Dictionary[Vector2, int] = {}
var _row_entry := 0
var _tip := 0
var _floor_y := 0.0
var _row := 0
var _column := 0
var _built := 0


func extend(geometry: RefCounted, row: int, row_start: int, placed_count: int) -> void:
	if _points.is_empty():
		var ground: Vector2 = geometry.platform(0)
		_add_point(Vector2(ground.x, 0.0), -1)
	var limit := mini(placed_count + 1, row_start + geometry.row_size(row))
	while _built < limit:
		var parent := _row_entry if _column == 0 else _tip
		var origin: Vector2 = geometry.brick_origin(_row, _column)
		var extent: Vector2 = geometry.brick_extent(_row, _column)
		var unit: Vector2 = geometry.brick_size()
		var new_floor := origin.y + unit.y * 0.0001 >= _floor_y
		if new_floor:
			_floor_y = origin.y + 2.0 * unit.y
			paths.append(PackedVector2Array([_points[parent]]))
		var work := Vector2(origin.x + extent.x * 0.5, _floor_y)
		if new_floor:
			parent = _append_stairs(parent, work, unit)
		_tip = _append(work, parent)
		_work_nodes[work] = _tip
		if _column == 0:
			_row_entry = _tip
		_built += 1
		_column += 1
		if _column == geometry.row_size(_row):
			_row += 1
			_column = 0


func _append_stairs(parent: int, work: Vector2, unit: Vector2) -> int:
	var start := _points[parent]
	var rise := work.y - start.y
	var flights := maxi(1, ceili(rise / (3.0 * unit.y) - 0.0001))
	var run := rise / flights * unit.x / unit.y * 0.8
	var landing_width := 0.75 * unit.x
	var bottom := Vector2(minf(start.x - landing_width, work.x - 1.5 * unit.x), start.y)
	parent = _append(bottom, parent)
	# The last flight climbs to the left, leaving a straight deck towards the work.
	var direction := -1.0 if flights % 2 == 1 else 1.0
	for point in flight_points(bottom, work.y, flights, run, landing_width, direction):
		parent = _append(point, parent)
	return parent


static func flight_points(start: Vector2, finish_y: float, flights: int, run: float,
		landing_width: float, first_direction: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	var bottom := start
	var direction := first_direction
	for flight in range(flights):
		var top := Vector2(bottom.x + direction * run, lerpf(start.y, finish_y, float(flight + 1) / flights))
		points.append(top)
		if flight + 1 < flights:
			bottom = top + Vector2(direction * landing_width, 0.0)
			points.append(bottom)
			direction = -direction
	return points


func tip() -> Vector2:
	return _points[_tip]


func row_entry() -> Vector2:
	return _points[_row_entry]


func route(start: Vector2, finish: Vector2) -> PackedVector2Array:
	if start.is_equal_approx(finish):
		return PackedVector2Array([start])
	if is_equal_approx(start.y, finish.y) and (is_zero_approx(start.y)
			or (_work_nodes.has(start) and _work_nodes.has(finish))):
		return deck_path(start, finish)
	var from := _chain_to_ground(_attachment(start))
	var to := _chain_to_ground(_attachment(finish))
	while from.size() > 1 and to.size() > 1 and from[-2] == to[-2]:
		from.resize(from.size() - 1)
		to.resize(to.size() - 1)
	var result := PackedVector2Array([start])
	for index in from:
		_append_distinct(result, _points[index])
	for step in range(to.size() - 2, -1, -1):
		_append_distinct(result, _points[to[step]])
	_append_distinct(result, finish)
	return result


func _attachment(point: Vector2) -> int:
	if is_zero_approx(point.y):
		return 0
	# A projected crossing does not replace a work point's connection.
	if _work_nodes.has(point):
		return _work_nodes[point]
	var best := 0
	var distance := INF
	for index in range(_points.size() - 1, -1, -1):
		var candidate := point.distance_squared_to(_points[index])
		if candidate < distance:
			best = index
			distance = candidate
			if is_zero_approx(distance):
				break
	return best


func _chain_to_ground(index: int) -> PackedInt32Array:
	var chain := PackedInt32Array()
	while index >= 0:
		chain.append(index)
		index = _parents[index]
	return chain


func _append(point: Vector2, parent: int) -> int:
	var path := paths[-1]
	_append_distinct(path, point)
	paths[-1] = path
	if _points[parent].is_equal_approx(point):
		return parent
	return _add_point(point, parent)


func _add_point(point: Vector2, parent: int) -> int:
	_points.append(point)
	_parents.append(parent)
	return _points.size() - 1


static func deck_path(start: Vector2, finish: Vector2) -> PackedVector2Array:
	var points := PackedVector2Array([start])
	_append_distinct(points, finish)
	return points


static func _append_distinct(points: PackedVector2Array, point: Vector2) -> void:
	if not points[-1].is_equal_approx(point):
		points.append(point)
