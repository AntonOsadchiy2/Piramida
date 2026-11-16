extends RefCounted
## Logical coordinates, with Y increasing upwards.
## Invalid cell and row lookups return null. Invalid routes are empty.

const QuarrySlopes = preload("res://scripts/domain/quarry_slopes.gd")

var _world: Dictionary
var _lift: Dictionary
var quarry_slopes: QuarrySlopes
var _quarry_cells: Array[Vector2i] = []
var _opened_depth := PackedInt32Array([0])


func _init(balance: Dictionary) -> void:
	_world = balance["world"].duplicate()
	_lift = balance["lift"].duplicate()
	if _world.get("quarrySlopesOnly", false):
		quarry_slopes = QuarrySlopes.new(_world)
	# Each pass adds the shoulders from the top down, then opens the next floor.
	for depth in range(quarry_layers()):
		for layer in range(depth):
			var radius := depth - layer
			_add_quarry_cell(Vector2i(-radius, layer))
			_add_quarry_cell(Vector2i(radius, layer))
		_add_quarry_cell(Vector2i(0, depth))


func _add_quarry_cell(cell: Vector2i) -> void:
	_quarry_cells.append(cell)
	_opened_depth.append(maxi(_opened_depth[-1], cell.y))


func quarry_count() -> int:
	return _quarry_cells.size()


func quarry_layers() -> int:
	return int(_world.quarryLayers)


func quarry_depth(mined: int) -> int:
	return _opened_depth[clampi(mined, 0, quarry_count())]


func quarry_grid_cell(resource_id: int) -> Vector2i:
	if resource_id < 0 or resource_id >= quarry_count():
		return Vector2i(0, -1)
	return _quarry_cells[resource_id]


func quarry_cell(resource_id: int) -> Variant:
	var cell := quarry_grid_cell(resource_id)
	if cell.y < 0:
		return null
	return quarry_grid_point(cell)


func quarry_grid_point(cell: Vector2) -> Vector2:
	return Vector2(
		float(_world.quarryCenterX) + cell.x * float(_world.quarryStepX),
		-float(_world.terraceDrop) - cell.y * float(_world.quarryLayerHeight)
	)


func quarry_mouth() -> Vector2:
	return quarry_grid_point(Vector2.ZERO)


func raw_storage() -> Vector2:
	return Vector2(_world.rawStorageX, 0)


func workshop() -> Vector2:
	return Vector2(_world.workshopX, 0)


func workshop_pickup() -> Vector2:
	return workshop() + Vector2(0.48, 0)


func finished_storage() -> Vector2:
	return platform(0)


func quarry_edge(layer: int, side: int, mined: int) -> Vector2:
	# Each floor is exposed by removing the cells immediately above it.
	var cut_layer := maxi(0, layer - 1)
	var depth := quarry_depth(mined)
	var extent := maxi(0, depth - cut_layer)
	# The next pass cuts the left shoulder first on each layer.
	var next_shoulder := (depth + 1) * (depth + 1) + 2 * cut_layer + int(side > 0)
	if mined > next_shoulder:
		extent += 1
	var margin := 0.5 if layer == 0 else 0.25
	return quarry_grid_point(Vector2(side * (extent + margin), layer))


func quarry_pickup(resource_id: int, mined: int = 0) -> Vector2:
	var cell := quarry_grid_cell(resource_id)
	if quarry_slopes != null:
		return quarry_slopes.point(quarry_grid_point(cell).x, mined)
	return quarry_grid_point(Vector2(cell.x, cell.y + 1))


func miner_work_position(resource_id: int, mined: int) -> Vector2:
	var position := quarry_grid_point(quarry_grid_cell(resource_id))
	return quarry_slopes.point(position.x, mined) if quarry_slopes != null else position


func quarry_stock() -> Vector2:
	return quarry_grid_point(Vector2(quarry_layers() - 0.5, 0)) + Vector2(1.5, 0)


func quarry_to_stock(resource_id: int, mined: int) -> PackedVector2Array:
	return _quarry_route(quarry_pickup(resource_id, mined), quarry_grid_cell(resource_id).y + 1,
		quarry_stock(), 0, mined, 1)


func miner_to_pickup(previous_id: int, target_id: int) -> PackedVector2Array:
	var previous := quarry_grid_cell(previous_id)
	var mined := previous_id + 1
	return _quarry_between(miner_work_position(previous_id, mined), previous.y,
		quarry_pickup(target_id, mined), quarry_grid_cell(target_id).y + 1, mined)


func quarry_stock_to_miner(previous_id: int) -> PackedVector2Array:
	var previous := quarry_grid_cell(previous_id)
	var mined := previous_id + 1
	return _quarry_route(quarry_stock(), 0, miner_work_position(previous_id, mined), previous.y, mined, 1)


func miner_to_lift_operator() -> PackedVector2Array:
	if quarry_slopes != null:
		var mined := quarry_count()
		return quarry_slopes.route(miner_work_position(mined - 1, mined), raw_storage(), mined) \
			+ PackedVector2Array([lift_operator_position()])
	var route := quarry_stock_to_miner(quarry_count() - 1)
	route.reverse()
	route.append(lift_operator_position())
	return route


func quarry_to_raw(resource_id: int, mined: int) -> PackedVector2Array:
	var cell := quarry_grid_cell(resource_id)
	if cell.y < 0:
		return PackedVector2Array()
	return _quarry_route(quarry_pickup(resource_id, mined), cell.y + 1, raw_storage(), 0, mined, 1)


func quarry_between_pickups(first_id: int, last_id: int, mined: int) -> PackedVector2Array:
	var first := quarry_grid_cell(first_id)
	var last := quarry_grid_cell(last_id)
	if first.y < 0 or last.y < 0:
		return PackedVector2Array()
	return _quarry_between(quarry_pickup(first_id, mined), first.y + 1,
		quarry_pickup(last_id, mined), last.y + 1, mined)


func miner_to_next_cell(previous_id: int) -> PackedVector2Array:
	if previous_id == -1:
		return PackedVector2Array([quarry_mouth()])
	var first := quarry_grid_cell(previous_id)
	var last := quarry_grid_cell(previous_id + 1)
	if first.y < 0 or last.y < 0:
		return PackedVector2Array()
	var mined := previous_id + 1
	return _quarry_between(miner_work_position(previous_id, mined), first.y,
		miner_work_position(previous_id + 1, mined), last.y, mined)


func _quarry_between(start: Vector2, start_layer: int, finish: Vector2, finish_layer: int,
		mined: int) -> PackedVector2Array:
	if quarry_slopes != null:
		return quarry_slopes.route(start, finish, mined)
	var right := _quarry_route(start, start_layer, finish, finish_layer, mined, 1)
	if start_layer == finish_layer:
		return right
	var left := _quarry_route(start, start_layer, finish, finish_layer, mined, -1)
	return left if route_length(left) < route_length(right) else right


func _quarry_route(start: Vector2, start_layer: int, finish: Vector2, finish_layer: int,
		mined: int, side: int) -> PackedVector2Array:
	if quarry_slopes != null:
		return quarry_slopes.route(start, finish, mined)
	var route := PackedVector2Array([start])
	if start_layer != finish_layer:
		var step := 1 if finish_layer > start_layer else -1
		for layer in range(start_layer, finish_layer + step, step):
			var edge := quarry_edge(layer, side, mined)
			if route[-1] != edge:
				route.append(edge)
	if route[-1] != finish:
		route.append(finish)
	return route


func row_size(row: int) -> int:
	if row < 0 or row >= int(_world.pyramidRows):
		return 0
	return int(_world.pyramidBaseRowBricks) - row * int(_world.rowWidthDecrease)


func brick_size() -> Vector2:
	return Vector2(_world.brickWidth, _world.brickHeight)


func brick_origin(row: int, column: int) -> Variant:
	if column < 0 or column >= row_size(row):
		return null
	var inset := (int(_world.pyramidBaseRowBricks) - row_size(row)) * 0.5
	return Vector2(_world.pyramidLeft + (inset + column) * brick_size().x, row * brick_size().y)


func platform(row: int) -> Variant:
	var first: Variant = brick_origin(row, 0)
	if first == null:
		return null
	return first - Vector2(_world.platformOffset, 0)


func lift_route(row: int) -> PackedVector2Array:
	var destination: Variant = platform(row)
	if destination == null or row == 0:
		return PackedVector2Array()
	var base := finished_storage()
	if has_upper_delivery():
		var travel_height := lift_cable_height(row) - lift_suspension() - brick_size().y
		return PackedVector2Array([
			base, Vector2(base.x, travel_height),
			Vector2(destination.x, travel_height), destination
		])
	return PackedVector2Array([
		base, Vector2(base.x, destination.y), destination
	])


func lift_operator_position() -> Vector2:
	return finished_storage() - Vector2(0.85, 0)


func platform_to_lift_operator(row: int) -> PackedVector2Array:
	var landing: Vector2 = platform(row)
	var base := finished_storage()
	if has_pyramid_ramp():
		if row == 0:
			return PackedVector2Array([base, lift_operator_position()])
		return PackedVector2Array([landing, base, lift_operator_position()])
	return PackedVector2Array([landing, Vector2(base.x, landing.y), base, lift_operator_position()])


func has_pyramid_ramp() -> bool:
	return _world.get("pyramidRamp", false)


func pyramid_ramp_step() -> Vector2:
	return Vector2(brick_size().x * int(_world.rowWidthDecrease) * 0.5, brick_size().y)


func pyramid_deck_entry(row: int) -> Vector2:
	var landing: Vector2 = platform(row)
	return landing + pyramid_ramp_step() if row > 0 else landing


func has_upper_delivery() -> bool:
	return _world.has("liftCableClearance")


func lift_cable_height(row: int) -> float:
	return (row + 1) * brick_size().y + float(_world.liftCableClearance)


func lift_suspension() -> float:
	return float(_world.liftSuspension)


func pyramid_right() -> float:
	return float(_world.pyramidLeft) + row_size(0) * brick_size().x


func lift_seconds(row: int) -> float:
	if row == 0 or row_size(row) == 0:
		return 0.0
	return float(_lift.baseSeconds) + row * float(_lift.secondsPerRow)


func rebuild_seconds() -> float:
	return float(_lift.rebuildSeconds)


func builder_to_brick(row: int, column: int) -> PackedVector2Array:
	var brick: Variant = brick_origin(row, column)
	if brick == null:
		return PackedVector2Array()
	var start: Vector2 = platform(row)
	var deck_y: float = brick.y + (brick_size().y if row > 0 else 0.0)
	if has_pyramid_ramp() and row > 0:
		var entry := pyramid_deck_entry(row)
		return PackedVector2Array([start, entry, Vector2(brick.x + brick_size().x * 0.5, entry.y)])
	return PackedVector2Array([
		start, Vector2(start.x, deck_y), Vector2(brick.x + brick_size().x * 0.5, deck_y)
	])


func platform_to_next_row(row: int) -> PackedVector2Array:
	var start: Variant = platform(row)
	var finish: Variant = platform(row + 1)
	if start == null or finish == null:
		return PackedVector2Array()
	if has_pyramid_ramp():
		return PackedVector2Array([start, finish])
	return PackedVector2Array([start, Vector2(start.x, finish.y), finish])


static func route_length(points: PackedVector2Array) -> float:
	var length := 0.0
	for index in range(1, points.size()):
		length += points[index - 1].distance_to(points[index])
	return length
