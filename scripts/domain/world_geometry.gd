extends RefCounted
## Logical coordinates, with Y increasing upwards.
## Invalid cell and row lookups return null. Invalid routes are empty.

const QuarrySlopes = preload("res://scripts/domain/quarry_slopes.gd")

var _world: Dictionary
var _lift: Dictionary
var quarry_slopes: QuarrySlopes
var _quarry_cells: Array[Vector2i] = []
var _opened_depth := PackedInt32Array([0])
var _blueprint_rows: Array[Array] = []
var _blueprint_levels: Array[int] = []
var _blueprint_blocks: Array[Dictionary] = []


func _init(balance: Dictionary) -> void:
	_world = balance["world"].duplicate()
	_lift = balance["lift"].duplicate()
	if _world.has("blueprintBlocks"):
		_blueprint_blocks = _world.blueprintBlocks.duplicate(true)
		for block: Dictionary in _blueprint_blocks:
			var level := int(block.y)
			if _blueprint_levels.is_empty() or _blueprint_levels[-1] != level:
				_blueprint_levels.append(level)
				_blueprint_rows.append([])
			_blueprint_rows[-1].append(block)
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
	# One ground-level dressing space inside the canopy, clear of its posts.
	return workshop() + Vector2(-0.95, 0)


func raw_storage_bounds() -> Vector2:
	# The clear strip between the canopy's right post and the lift operator's path.
	return Vector2(workshop().x + 2.55, lift_operator_position().x - 0.30)


func raw_block_width(resource_id: int) -> float:
	# stone.png visible alpha bounds: 46 px, drawn at 0.94 scale.
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
			return first - Vector2(_world.platformOffset, 0)
		# Keep the landing outside every placed block, including tall blocks
		# from earlier stages that can surround the next stage's first block.
		var right_edge := 0
		for stage: Array in _blueprint_rows:
			for block: Dictionary in stage:
				right_edge = maxi(right_edge, int(block.x) + int(block.size))
		return Vector2(float(_world.pyramidLeft) + (right_edge + 0.25) * brick_size().x, 0.0)
	return first - Vector2(_world.platformOffset, 0)


func lift_route(row: int, landing: Variant = null) -> PackedVector2Array:
	var destination: Variant = landing if landing != null else platform(row)
	if destination == null or row == 0:
		return PackedVector2Array()
	var base := finished_storage()
	if has_upper_delivery():
		var next_size := int(block_for_placement(placement_start_for_stage(row)).get("size", 1))
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


func pyramid_ramp_step(row: int = 0) -> Vector2:
	if not _blueprint_rows.is_empty():
		return Vector2(0, stage_top_height(row) - stage_height(row))
	return Vector2(brick_size().x * int(_world.rowWidthDecrease) * 0.5, brick_size().y)


func pyramid_deck_entry(row: int) -> Vector2:
	var landing: Vector2 = platform(row)
	return landing + pyramid_ramp_step(row) if row > 0 else landing


func has_upper_delivery() -> bool:
	return _world.has("liftCableClearance")


func lift_cable_height(row: int) -> float:
	return stage_top_height(row) + float(_world.liftCableClearance)


func lift_suspension() -> float:
	return float(_world.liftSuspension)


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


func builder_to_brick(row: int, column: int) -> PackedVector2Array:
	var brick: Variant = brick_origin(row, column)
	if brick == null:
		return PackedVector2Array()
	var extent := brick_extent(row, column)
	var start: Vector2 = platform(row)
	var deck_y: float = stage_top_height(row) if row > 0 else brick.y
	if has_pyramid_ramp() and row > 0:
		var entry := pyramid_deck_entry(row)
		return PackedVector2Array([start, entry, Vector2(brick.x + extent.x * 0.5, entry.y)])
	return PackedVector2Array([
		start, Vector2(start.x, deck_y), Vector2(brick.x + extent.x * 0.5, deck_y)
	])


func block_screen_extent(row: int, column: int) -> Vector2:
	return brick_extent(row, column) * 100.0


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
func scaffold_snapshot(placed: Dictionary, landing: Vector2, work: Vector2,
		settings: Dictionary = {}) -> Dictionary:
	var unit := brick_size()
	var width: float = float(settings.get("section_width", 4.0 * unit.x))
	var post_width: float = float(settings.get("post_width", 0.20 * unit.x))
	var max_post_height: float = float(settings.get("max_post_height", 5.0 * unit.y))
	var max_span: float = float(settings.get("max_span", 4.0 * unit.x))
	var max_void_width: float = float(settings.get("max_void_width", 2.0 * unit.x))
	var max_void_depth: float = float(settings.get("max_void_depth", 4.0 * unit.y))
	var max_transition_rise: float = float(settings.get("max_transition_rise", 4.0 * unit.y))
	var max_transition_length: float = float(settings.get("max_transition_length", 5.0 * unit.x))
	var worker_width: float = float(settings.get("worker_width", 0.18 * unit.x))
	var worker_height: float = float(settings.get("worker_height", 0.9 * unit.y))
	var clearance: float = float(settings.get("clearance", 0.02 * unit.y))
	var result := {"ok": false, "reason": "invalid_settings", "sections": [],
		"posts": [], "transitions": []}
	if width <= post_width * 2.0 or post_width <= 0.0 or width > max_span \
			or max_post_height < 0.0 or max_void_width < 0.0 or max_void_depth < 0.0 \
			or max_transition_rise < 0.0 or max_transition_length <= 0.0 \
			or worker_width <= 0.0 or worker_height <= 0.0:
		return result
	# Stable local positions. The work point remains within the deck in every try.
	var step := unit.x * 0.25
	var centered := work.x - width * 0.5
	var offsets := [0, -1, 1, -2, 2, -3, 3, -4, 4]
	var last_reason := "no_supported_position"
	for offset in offsets:
		var x0: float = centered + float(offset) * step
		var x1 := x0 + width
		if work.x < x0 + worker_width * 0.5 or work.x > x1 - worker_width * 0.5:
			continue
		var left := _scaffold_post(placed, x0, work.y, post_width, max_post_height)
		var right := _scaffold_post(placed, x1 - post_width, work.y,
			post_width, max_post_height)
		if left.is_empty() or right.is_empty():
			last_reason = "post_without_support"
			continue
		if not _scaffold_clear_segment(placed, Vector2(x0, work.y),
				Vector2(x1, work.y), worker_width, worker_height, clearance):
			last_reason = "deck_blocked"
			continue
		if not _scaffold_void_allowed(placed, x0, x1, work.y,
				max_void_width, max_void_depth):
			last_reason = "void_limit"
			continue
		var entry := Vector2(x0, work.y) if landing.x <= work.x else Vector2(x1, work.y)
		if not is_equal_approx(landing.y, entry.y):
			var direction := 1.0 if landing.x <= work.x else -1.0
			entry.x = clampf((landing.x + work.x) * 0.5, x0, x1)
			if (entry.x - landing.x) * direction < 0.1 * unit.x:
				last_reason = "transition_too_steep"
				continue
		if absf(entry.y - landing.y) > max_transition_rise \
				or entry.distance_to(landing) > max_transition_length:
			last_reason = "transition_limit"
			continue
		if not _scaffold_clear_segment(placed, landing, entry,
				worker_width, worker_height, clearance):
			last_reason = "transition_blocked"
			continue
		var key := "deck:%0.4f:%0.4f:%0.4f" % [x0, x1, work.y]
		left["id"] = key + ":left"
		right["id"] = key + ":right"
		result.ok = true
		result.reason = ""
		result.sections = [{"id": key, "x0": x0, "x1": x1, "y": work.y,
			"post_ids": [left.id, right.id]}]
		result.posts = [left, right]
		result.transitions = [{"id": key + ":entry", "from": landing,
			"to": entry, "kind": "level" if is_equal_approx(landing.y, entry.y) else "slope"}]
		return result
	result.reason = last_reason
	return result


## Builds an exact horizontal run. Every section is short enough for the
## configured span and every joint has a post to actual masonry or ground.
func scaffold_run_snapshot(placed: Dictionary, start: Vector2, finish: Vector2,
		settings: Dictionary = {}) -> Dictionary:
	var unit := brick_size()
	var post_width: float = float(settings.get("post_width", 0.20 * unit.x))
	var max_post_height: float = float(settings.get("max_post_height", 5.0 * unit.y))
	var max_span: float = float(settings.get("max_span", 4.0 * unit.x))
	var max_void_width: float = float(settings.get("max_void_width", 2.0 * unit.x))
	var max_void_depth: float = float(settings.get("max_void_depth", 4.0 * unit.y))
	var worker_width: float = float(settings.get("worker_width", 0.18 * unit.x))
	var worker_height: float = float(settings.get("worker_height", 0.9 * unit.y))
	var clearance: float = float(settings.get("clearance", 0.02 * unit.y))
	var result := {"ok": false, "reason": "invalid_settings", "sections": [],
		"posts": [], "transitions": []}
	if not is_equal_approx(start.y, finish.y) or finish.x <= start.x \
			or post_width <= 0.0 or max_span <= post_width or max_post_height < 0.0:
		return result
	if not _scaffold_clear_segment(placed, start, finish,
			worker_width, worker_height, clearance):
		result.reason = "deck_blocked"
		return result
	var section_count := maxi(1, ceili((finish.x - start.x) / max_span))
	var joints: Array[float] = []
	for index in range(section_count + 1):
		joints.append(lerpf(start.x, finish.x, float(index) / float(section_count)))
	var posts: Array[Dictionary] = []
	for index in range(joints.size()):
		var joint := joints[index]
		var centered := clampf(joint - post_width * 0.5,
			start.x, finish.x - post_width)
		var post: Dictionary = {}
		for offset in [0.0, -post_width, post_width, -2.0 * post_width, 2.0 * post_width]:
			var post_x := clampf(centered + offset, start.x, finish.x - post_width)
			post = _scaffold_post(placed, post_x, start.y, post_width, max_post_height)
			if not post.is_empty():
				break
		if post.is_empty():
			result.reason = "post_without_support"
			return result
		post["id"] = "run-post:%0.4f:%0.4f:%d" % [joint, start.y, index]
		posts.append(post)
	var sections: Array[Dictionary] = []
	for index in range(section_count):
		var x0 := joints[index]
		var x1 := joints[index + 1]
		if not _scaffold_void_allowed(placed, x0, x1, start.y,
				max_void_width, max_void_depth):
			result.reason = "void_limit"
			return result
		sections.append({"id": "run:%0.4f:%0.4f:%0.4f" % [x0, x1, start.y],
			"x0": x0, "x1": x1, "y": start.y,
			"post_ids": [posts[index].id, posts[index + 1].id]})
	result.ok = true
	result.reason = ""
	result.sections = sections
	result.posts = posts
	return result


func _scaffold_post(placed: Dictionary, x0: float, top: float,
		post_width: float, max_height: float) -> Dictionary:
	var x1 := x0 + post_width
	var center := (x0 + x1) * 0.5
	var support := support_below(placed, Vector2(center, top))
	if support.is_empty() or support.x0 > x0 or support.x1 < x1:
		return {}
	if top - float(support.y) > max_height + 0.00001 \
			or top < float(support.y) - 0.00001:
		return {}
	for block: Dictionary in placed.blocks:
		if block.x0 < x1 and block.x1 > x0 \
				and block.y0 < top and block.y1 > float(support.y):
			return {}
	return {"x0": x0, "x1": x1, "y0": support.y, "y1": top,
		"support_id": support.id}


func _scaffold_void_allowed(placed: Dictionary, x0: float, x1: float,
		deck_y: float, max_width: float, max_depth: float) -> bool:
	# Measure the original profile before adding posts. Split at every block edge.
	var cuts: Array[float] = [x0, x1]
	for block: Dictionary in placed.blocks:
		if block.x0 > x0 and block.x0 < x1:
			cuts.append(block.x0)
		if block.x1 > x0 and block.x1 < x1:
			cuts.append(block.x1)
	for surface: Dictionary in placed.surfaces:
		if surface.x0 > x0 and surface.x0 < x1:
			cuts.append(surface.x0)
		if surface.x1 > x0 and surface.x1 < x1:
			cuts.append(surface.x1)
	cuts.sort()
	var void_start := INF
	for i in range(cuts.size() - 1):
		var a := cuts[i]
		var b := cuts[i + 1]
		if b <= a:
			continue
		var support := support_below(placed, Vector2((a + b) * 0.5, deck_y))
		if support.is_empty() or deck_y - float(support.y) > max_depth:
			if is_inf(void_start):
				void_start = a
			if b - void_start > max_width:
				return false
		else:
			void_start = INF
	return true


func _scaffold_clear_segment(placed: Dictionary, start: Vector2, finish: Vector2,
		worker_width: float, worker_height: float, clearance: float) -> bool:
	# Clip the whole center segment against each block expanded by worker size.
	# Exact intervals include joints and narrow overhangs between sample points.
	for block: Dictionary in placed.blocks:
		var minimum := Vector2(float(block.x0) - worker_width * 0.5 + 0.00001,
			float(block.y0) - worker_height - clearance + 0.00001)
		var maximum := Vector2(float(block.x1) + worker_width * 0.5 - 0.00001,
			float(block.y1) - 0.00001)
		if _segment_enters_open_rect(start, finish, minimum, maximum):
			return false
	return true


func _segment_enters_open_rect(start: Vector2, finish: Vector2,
		minimum: Vector2, maximum: Vector2) -> bool:
	var lower := 0.0
	var upper := 1.0
	var delta := finish - start
	for axis in range(2):
		var value: float = start.x if axis == 0 else start.y
		var movement: float = delta.x if axis == 0 else delta.y
		var low: float = minimum.x if axis == 0 else minimum.y
		var high: float = maximum.x if axis == 0 else maximum.y
		if absf(movement) < 0.00000001:
			if value <= low or value >= high:
				return false
			continue
		var enter := (low - value) / movement
		var leave := (high - value) / movement
		lower = maxf(lower, minf(enter, leave))
		upper = minf(upper, maxf(enter, leave))
		if lower >= upper:
			return false
	return true
