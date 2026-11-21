extends RefCounted
## Logical coordinates, with Y increasing upwards.
## Invalid cell and row lookups return null. Invalid routes are empty.

const QuarryExcavation = preload("res://scripts/domain/quarry_excavation.gd")
const QuarrySlopes = preload("res://scripts/domain/quarry_slopes.gd")
const LIMESTONE_SCALE := 1.15
const OVERVIEW_GROUND_FROM_BOTTOM := 0.20
const OVERVIEW_QUARRY_MARGIN := 0.05
const OVERVIEW_QUARRY_PADDING := 0.6
const QUARRY_SHIFT_X := -4.4
const RAW_STORAGE_SHIFT_X := -7.80

var _world: Dictionary
var _lift: Dictionary
var quarry_slopes: QuarrySlopes
var quarry_excavation: QuarryExcavation
var _quarry_cells: Array[Vector2i] = []
var _opened_depth := PackedInt32Array([0])
var _blueprint_rows: Array[Array] = []
var _blueprint_levels: Array[int] = []
var _blueprint_blocks: Array[Dictionary] = []


func _init(balance: Dictionary) -> void:
	_world = balance["world"].duplicate()
	_world.quarryCenterX += QUARRY_SHIFT_X
	_lift = balance["lift"].duplicate()
	if _world.has("blueprintBlocks"):
		_blueprint_blocks = _world.blueprintBlocks.duplicate(true)
		for block: Dictionary in _blueprint_blocks:
			var level := int(block.y)
			if _blueprint_levels.is_empty() or _blueprint_levels[-1] != level:
				_blueprint_levels.append(level)
				_blueprint_rows.append([])
			_blueprint_rows[-1].append(block)
	if _world.get("quarryBlockCuts", false):
		var width := (quarry_layers() * 2 - 1) * float(_world.quarryStepX)
		quarry_excavation = QuarryExcavation.new(_world, brick_size() * LIMESTONE_SCALE,
			width, resource_sizes(), block_count(), pyramid_width() * 0.5)
		quarry_slopes = quarry_excavation
	elif _world.get("quarrySlopesOnly", false):
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
	return quarry_excavation.mouth() if quarry_excavation != null else quarry_grid_point(Vector2.ZERO)


func raw_storage() -> Vector2:
	return Vector2(raw_storage_bounds().x - 0.10, 0)


func workshop() -> Vector2:
	return Vector2(_world.workshopX, 0)


func workshop_pickup() -> Vector2:
	# One ground-level dressing space inside the canopy, clear of its posts.
	return workshop() + Vector2(-0.95, 0)


func raw_storage_bounds() -> Vector2:
	# Leave clearance to the canopy's left post.
	return Vector2(workshop().x - 5.25, workshop().x - 2.55)


func raw_block_width(resource_id: int) -> float:
	# Keep the same slot widths when restoring saved raw positions.
	return 46.0 * 0.94 * block_size_for_resource(resource_id) / 100.0


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
	if quarry_excavation != null:
		return quarry_excavation.pickup_position(resource_id)
	var cell := quarry_grid_cell(resource_id)
	if quarry_slopes != null:
		return quarry_slopes.point(quarry_grid_point(cell).x, mined)
	return quarry_grid_point(Vector2(cell.x, cell.y + 1))


func miner_work_position(resource_id: int, mined: int) -> Vector2:
	if quarry_excavation != null:
		return quarry_excavation.work_position(resource_id)
	var position := quarry_grid_point(quarry_grid_cell(resource_id))
	return quarry_slopes.point(position.x, mined) if quarry_slopes != null else position


func legacy_quarry_stock() -> Vector2:
	return quarry_grid_point(Vector2(quarry_layers() - 0.5, 0)) + Vector2(1.5 - QUARRY_SHIFT_X, 0)


func miner_to_pickup(previous_id: int, target_id: int) -> PackedVector2Array:
	var previous := quarry_grid_cell(previous_id)
	var mined := previous_id + 1
	return _quarry_between(miner_work_position(previous_id, mined), previous.y,
		quarry_pickup(target_id, mined), quarry_grid_cell(target_id).y + 1, mined)


func raw_to_miner(previous_id: int, start: Vector2) -> PackedVector2Array:
	var previous := quarry_grid_cell(previous_id)
	var mined := previous_id + 1
	var route := _quarry_route(raw_storage(), 0, miner_work_position(previous_id, mined), previous.y, mined, 1)
	if start != route[0]:
		route.insert(0, start)
	return route


func miner_to_lift_operator(mined_count: int = -1, start := Vector2.INF) -> PackedVector2Array:
	if quarry_slopes != null:
		var mined := quarry_count() if mined_count < 0 else mined_count
		var entry := miner_work_position(mined - 1, mined) if start == Vector2.INF else start
		return quarry_slopes.route(entry, raw_storage(), mined) \
			+ PackedVector2Array([lift_operator_position()])
	var route := raw_to_miner(quarry_count() - 1, raw_storage())
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
		if quarry_excavation != null:
			return quarry_excavation.route(quarry_mouth(), miner_work_position(0, 0), 0)
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


func row_count() -> int:
	if not _blueprint_rows.is_empty():
		return _blueprint_rows.size()
	return int(_world.pyramidRows)


func row_size(row: int) -> int:
	if not _blueprint_rows.is_empty():
		return _blueprint_rows[row].size() if row >= 0 and row < _blueprint_rows.size() else 0
	if row < 0 or row >= int(_world.pyramidRows):
		return 0
	return int(_world.pyramidBaseRowBricks) - row * int(_world.rowWidthDecrease)


func brick_size() -> Vector2:
	return Vector2(_world.brickWidth, _world.brickHeight)


func block_at(row: int, column: int) -> Dictionary:
	if row < 0 or row >= row_count() or column < 0 or column >= row_size(row):
		return {}
	if not _blueprint_rows.is_empty():
		return _blueprint_rows[row][column].duplicate()
	var inset := (int(_world.pyramidBaseRowBricks) - row_size(row)) * 0.5
	return {"x": inset + column, "y": row, "type": "stone", "size": 1}


func block_for_placement(index: int) -> Dictionary:
	if index < 0 or index >= block_count():
		return {}
	if not _blueprint_blocks.is_empty():
		return _blueprint_blocks[index].duplicate()
	var remaining := index
	for row in range(row_count()):
		if remaining < row_size(row):
			return block_at(row, remaining)
		remaining -= row_size(row)
	return {}


func block_count() -> int:
	if not _blueprint_blocks.is_empty():
		return _blueprint_blocks.size()
	var count := 0
	for row in range(row_count()):
		count += row_size(row)
	return count


func block_size_for_resource(resource_id: int) -> int:
	if resource_id < 0 or resource_id >= _blueprint_blocks.size():
		return 1
	return int(_blueprint_blocks[resource_id].get("size", 1))


func texture_for_resource(resource_id: int, raw: bool) -> String:
	if resource_id < 0 or resource_id >= _blueprint_blocks.size():
		return ""
	return _blueprint_blocks[resource_id].get("rawTexture" if raw else "finishedTexture", "")


func resource_sizes() -> Array[int]:
	var sizes: Array[int] = []
	for resource_id in range(900):
		sizes.append(block_size_for_resource(resource_id))
	return sizes


func placement_start_for_stage(row: int) -> int:
	var result := 0
	for index in range(clampi(row, 0, row_count())):
		result += row_size(index)
	return result


func block_multiplier(resource_id: int) -> float:
	var size := block_size_for_resource(resource_id)
	return 1.0 if size <= 1 else size * float(_world.get("sizePenalty", 1.5))


func brick_extent(row: int, column: int) -> Vector2:
	var size := int(block_at(row, column).get("size", 1))
	return brick_size() * size


func stage_height(row: int) -> float:
	if row < 0 or row >= row_count():
		return 0.0
	return float(_blueprint_levels[row] if not _blueprint_rows.is_empty() else row) * brick_size().y


func stage_top_height(row: int) -> float:
	if row < 0 or row >= row_count():
		return 0.0
	var top := stage_height(row)
	for column in range(row_size(row)):
		var block := block_at(row, column)
		top = maxf(top, (float(block.y) + int(block.size)) * brick_size().y)
	return top


func brick_origin(row: int, column: int) -> Variant:
	if column < 0 or column >= row_size(row):
		return null
	if not _blueprint_rows.is_empty():
		var block := block_at(row, column)
		return Vector2(float(_world.pyramidLeft) + int(block.x) * brick_size().x, int(block.y) * brick_size().y)
	var inset := (int(_world.pyramidBaseRowBricks) - row_size(row)) * 0.5
	return Vector2(_world.pyramidLeft + (inset + column) * brick_size().x, row * brick_size().y)


func platform(row: int) -> Variant:
	var first: Variant = brick_origin(row, 0)
	if first == null:
		return null
	if not _blueprint_rows.is_empty():
		if row == 0:
			return Vector2(first.x - float(_world.platformOffset), 0.0)
		# Keep the landing outside every placed block, including tall blocks
		# from earlier stages that can surround the next stage's first block.
		var right_edge := 0
		for stage: Array in _blueprint_rows:
			for block: Dictionary in stage:
				right_edge = maxi(right_edge, int(block.x) + int(block.size))
		return Vector2(float(_world.pyramidLeft) + (right_edge + 0.25) * brick_size().x, 0.0)
	return first - Vector2(_world.platformOffset, 0)


func lift_route(row: int, landing: Variant = null, cargo_size: int = 0) -> PackedVector2Array:
	var destination: Variant = landing if landing != null else platform(row)
	if destination == null or row == 0:
		return PackedVector2Array()
	var base := finished_storage()
	if has_upper_delivery():
		var next_size := cargo_size if cargo_size > 0 else int(block_at(row, 0).size)
		var travel_height := lift_cable_height(row) - lift_suspension() - brick_size().y * next_size
		return PackedVector2Array([
			base, Vector2(base.x, travel_height),
			Vector2(destination.x, travel_height), destination
		])
	return PackedVector2Array([
		base, Vector2(base.x, destination.y), destination
	])


func lift_operator_position() -> Vector2:
	return finished_storage() - Vector2(0.85, 0)


func has_upper_delivery() -> bool:
	return _world.has("liftCableClearance")


func lift_cable_height(row: int) -> float:
	return stage_top_height(row) + float(_world.liftCableClearance)


func lift_suspension() -> float:
	return float(_world.liftSuspension)


func overview_bounds(quarry_frame: Rect2) -> Rect2:
	var left := minf(-12.05, quarry_frame.position.x - OVERVIEW_QUARRY_PADDING)
	var right := maxf(pyramid_right() + 1.25, quarry_frame.end.x + OVERVIEW_QUARRY_PADDING)
	var top := -pyramid_top() - 1.8
	var bottom := -quarry_frame.position.y
	return Rect2(left, top, right - left, bottom - top)


static func overview_zoom(bounds: Rect2, viewport_size: Vector2) -> float:
	var width_zoom := viewport_size.x / bounds.size.x
	var upper_zoom := viewport_size.y * (1.0 - OVERVIEW_GROUND_FROM_BOTTOM) / -bounds.position.y
	var quarry_zoom := viewport_size.y * (OVERVIEW_GROUND_FROM_BOTTOM - OVERVIEW_QUARRY_MARGIN) / bounds.end.y
	return minf(width_zoom, minf(upper_zoom, quarry_zoom))


func pyramid_width() -> float:
	var left := float(_world.pyramidLeft)
	if not _blueprint_blocks.is_empty():
		var first_column := int(_blueprint_blocks[0].x)
		for block in _blueprint_blocks:
			first_column = mini(first_column, int(block.x))
		left += first_column * brick_size().x
	return pyramid_right() - left


func pyramid_right() -> float:
	if not _blueprint_rows.is_empty():
		var right := 0.0
		for block in _blueprint_blocks:
			right = maxf(right, float(block.x + block.size))
		return float(_world.pyramidLeft) + right * brick_size().x
	return float(_world.pyramidLeft) + row_size(0) * brick_size().x


func pyramid_top() -> float:
	if not _blueprint_blocks.is_empty():
		var top := 0
		for block in _blueprint_blocks:
			top = maxi(top, int(block.y) + int(block.size))
		return top * brick_size().y
	return row_count() * brick_size().y


func lift_seconds(row: int) -> float:
	if row == 0 or row_size(row) == 0:
		return 0.0
	return float(_lift.baseSeconds) + row * float(_lift.secondsPerRow)


func rebuild_seconds() -> float:
	return float(_lift.rebuildSeconds)


func block_screen_extent(row: int, column: int) -> Vector2:
	return brick_extent(row, column) * 100.0


static func route_length(points: PackedVector2Array) -> float:
	var length := 0.0
	for index in range(1, points.size()):
		length += points[index - 1].distance_to(points[index])
	return length


func has_custom_blueprint() -> bool:
	return not _blueprint_blocks.is_empty()


## A snapshot is independent of route planning. Coordinates are logical world units,
## Y points up. Rectangles and exposed horizontal surfaces carry stable resource IDs.
## Ground extends across the world; a block resting on it hides its footprint.
func placed_surface_snapshot(placed_ids: Array) -> Dictionary:
	var ids: Array[int] = []
	for value in placed_ids:
		var id := int(value)
		if id >= 0 and id < block_count() and not ids.has(id):
			ids.append(id)
	ids.sort()
	var blocks: Array[Dictionary] = []
	for id in ids:
		var block := block_for_placement(id)
		var remaining := id
		var row := 0
		while remaining >= row_size(row):
			remaining -= row_size(row)
			row += 1
		var origin: Vector2 = brick_origin(row, remaining)
		var extent := brick_extent(row, remaining)
		blocks.append({
			"id": id, "x0": origin.x, "x1": origin.x + extent.x,
			"y0": origin.y, "y1": origin.y + extent.y,
			"size": int(block.get("size", 1)),
		})
	var surfaces: Array[Dictionary] = []
	var ground_cuts: Array[Dictionary] = []
	for block in blocks:
		if is_zero_approx(block.y0):
			ground_cuts.append(block)
	_append_open_surfaces(surfaces, "ground", -1, -INF, INF, 0.0, ground_cuts)
	for block in blocks:
		_append_open_surfaces(surfaces, "block", block.id, block.x0, block.x1,
			block.y1, blocks)
	return {"blocks": blocks, "surfaces": surfaces}


func _append_open_surfaces(result: Array[Dictionary], kind: String, source_id: int,
		x0: float, x1: float, height: float, blockers: Array[Dictionary]) -> void:
	var cuts: Array[Dictionary] = []
	for blocker in blockers:
		if blocker.id == source_id or not is_equal_approx(blocker.y0, height):
			continue
		var left := maxf(x0, float(blocker.x0))
		var right := minf(x1, float(blocker.x1))
		if left < right:
			cuts.append({"x0": left, "x1": right})
	cuts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.x0 < b.x0 if a.x0 != b.x0 else a.x1 < b.x1)
	var cursor := x0
	var part := 0
	for cut in cuts:
		if cut.x0 > cursor:
			result.append({"id": "%s:%d:%d" % [kind, source_id, part],
				"source": kind, "source_id": source_id,
				"x0": cursor, "x1": cut.x0, "y": height})
			part += 1
		cursor = maxf(cursor, float(cut.x1))
	if cursor < x1:
		result.append({"id": "%s:%d:%d" % [kind, source_id, part],
			"source": kind, "source_id": source_id,
			"x0": cursor, "x1": x1, "y": height})


## Returns an exposed surface at or below the point, or {} when the point is
## inside masonry or below ground. Clearance and post width belong to stage 2.
func support_below(snapshot: Dictionary, point: Vector2) -> Dictionary:
	for block: Dictionary in snapshot.blocks:
		if point.x > block.x0 and point.x < block.x1 \
				and point.y > block.y0 + 0.00001 \
				and point.y < block.y1 - 0.00001:
			return {}
	var nearest: Dictionary = {}
	for surface: Dictionary in snapshot.surfaces:
		if point.x < surface.x0 or point.x > surface.x1 \
				or surface.y > point.y + 0.00001:
			continue
		if nearest.is_empty() or surface.y > nearest.y:
			nearest = surface
	return nearest.duplicate()


## Independent scaffold candidate for one work point. The caller may retain this
## snapshot for both navigation and drawing; no worker state is changed here.
## All dimensions are logical world units. A rejected candidate has an explicit
## reason and no partial geometry.
