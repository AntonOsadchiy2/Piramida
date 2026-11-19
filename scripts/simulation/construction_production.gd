extends RefCounted

const State = preload("res://scripts/domain/game_state.gd")
const Routes = preload("res://scripts/domain/placed_route.gd")
const Owner = State.Owner

var _state: State
var _process_seconds: float
var _place_seconds: float
var _unload_seconds: float
var _builder_speed: float
var _miner_speed: float
var _porter_speed: float
var _dresser_speed: float
var _route_revision := -1
var _route_row := -1
var _route_generation := 0
var _change_x0 := -INF
var _change_x1 := INF
var _placed_snapshot: Dictionary = {}
var _scaffolds: Array = []
var _waiting: Dictionary[int, StringName] = {}
var _waiting_attempt: Dictionary[int, int] = {}
var _waiting_reason: Dictionary[int, String] = {}
var _route_failure := ""
var _delivery_attempt_generation := -1
var _delivery_attempt_phase := &""


func _init(state: State, balance: Dictionary) -> void:
	_state = state
	_process_seconds = float(balance.workers.dresser.processSeconds)
	_place_seconds = float(balance.workers.builder.placeSeconds)
	_unload_seconds = float(balance.workers.porter.unloadSeconds)
	_builder_speed = float(balance.workers.builder.moveSpeed)
	_miner_speed = float(balance.workers.miner.moveSpeed)
	_porter_speed = float(balance.workers.porter.emptySpeed)
	_dresser_speed = float(balance.workers.dresser.get("moveSpeed", _builder_speed))


func migrate_pyramid_routes() -> bool:
	var geometry := _state.geometry
	var row := _state.current_row
	if row == 0 or not geometry.has_pyramid_ramp():
		return true
	return _state.worker(_state.active_builder_id).remap_saved_routes(
		func(phase: StringName, route: PackedVector2Array) -> PackedVector2Array:
			var landing: Vector2 = _landing()
			var entry := geometry.pyramid_deck_entry(row)
			match phase:
				&"walk_to_lift", &"walk_to_workshop":
					if route[0].is_equal_approx(landing):
						var descent := geometry.platform_to_lift_operator(row)
						if phase == &"walk_to_workshop":
							descent.append(route[-1])
						return descent
				&"return_from_lift":
					var ascent := geometry.platform_to_lift_operator(row)
					if route[0].is_equal_approx(geometry.finished_storage()):
						ascent.resize(ascent.size() - 1)
					ascent.reverse()
					return ascent
				&"climb_to_platform":
					return geometry.platform_to_next_row(row - 1)
				&"walk_to_brick":
					return PackedVector2Array([landing, entry, Vector2(route[-1].x, entry.y)])
				&"return_to_platform":
					return PackedVector2Array([Vector2(route[0].x, entry.y), entry, landing])
			return route)


func apply_completion(event: Dictionary) -> void:
	match event.state:
		&"process_brick":
			_deliver(event.worker_id)
		&"lift_brick":
			if _deliver(Owner.LIFT):
				_state.worker(Owner.LIFT).position = _state.geometry.finished_storage()
		&"walk_to_lift":
			_start_manual_lift(event.worker_id)
		&"walk_to_workshop":
			_pick_up_at_workshop()
		&"walk_to_lift_base":
			var builder := _state.worker(_state.active_builder_id)
			if builder.fsm_state == &"walk_to_lift":
				# Older saves already have the walk to the crank queued.
				_deliver(_state.active_builder_id)
			else:
				builder.queue_work(&"unload_at_lift", _unload_seconds, 1.0)
		&"unload_at_lift":
			if _deliver(_state.active_builder_id):
				_after_builder_unload()
		&"place_brick":
			var placement_index := _state.placed_count()
			if _deliver(_state.active_builder_id):
				event["placement_index"] = placement_index
				_replan_active_moves()
				var row_complete := _state.placed_count() == _state.row_start + _state.geometry.row_size(_state.current_row)
				if row_complete:
					_state.completed_rows += 1
				_state.finished = _state.placed_count() == _state.target_count()
				var builder := _state.worker(_state.active_builder_id)
				if not _state.finished and builder.fsm_state == &"idle":
					_queue_return()
		&"return_to_platform":
			_rotate_builder()
		&"rebuild_platform":
			_state.current_row += 1
			_state.row_start = _state.placed_count()
			_queue_construction_move(_state.worker(_state.active_builder_id), &"climb_to_platform",
				_landing(), _builder_speed)


func _rotate_builder() -> void:
	var builders := _state.worker_ids_for_role(State.Worker.Role.BUILDER)
	if builders.size() < 2:
		return
	var index := builders.find(_state.active_builder_id)
	for offset in range(1, builders.size()):
		var id: int = builders[(index + offset) % builders.size()]
		var next := _state.worker(id)
		if next.fsm_state != &"idle":
			continue
		var geometry := _state.geometry
		var landing: Vector2 = _landing()
		_state.active_builder_id = id
		if not next.position.is_equal_approx(landing):
			_queue_construction_move(next, &"join_platform", landing, _builder_speed)
		return


func assign_tasks() -> void:
	_retry_paused_moves()
	var dressers := _state.worker_ids_for_role(State.Worker.Role.DRESSER)
	var start := _state.next_dresser_index
	for offset in range(dressers.size()):
		var index := (start + offset) % dressers.size()
		var id := dressers[index]
		var dresser := _state.worker(id)
		var next_input := _next_raw_resource()
		if dresser.fsm_state == &"idle" and next_input >= 0 \
				and _take_input(id, _state.owner_of(next_input), next_input):
			dresser.queue_work(&"process_brick", _process_seconds, 1.0)
			_state.next_dresser_index = (index + 1) % dressers.size()

	var lift := _state.worker(Owner.LIFT)
	var builder := _state.worker(_state.active_builder_id)
	var geometry := _state.geometry
	var row := _state.current_row
	_refresh_routes()
	if geometry.has_custom_blueprint() and row > 0 \
			and not _state.delivery_point.is_finite() \
			and _state.stock_count(Owner.PLATFORM) == 0 \
			and lift.fsm_state == &"idle" \
			and (_delivery_attempt_generation != _route_generation \
				or _delivery_attempt_phase != builder.fsm_state):
		_delivery_attempt_generation = _route_generation
		_delivery_attempt_phase = builder.fsm_state
		_state.delivery_point = _choose_delivery_point()
	_retry_waiting_helpers()
	if _state.completed_rows > row:
		if builder.fsm_state == &"idle" and _waiting.get(builder.id) == &"return_to_platform":
			_waiting.erase(builder.id)
			builder.route_waiting = false
		if _waiting.has(builder.id):
			_retry_builder_route(builder)
			return
		if builder.fsm_state == &"idle" and lift.fsm_state == &"idle":
			builder.queue_work(&"rebuild_platform", geometry.rebuild_seconds(), 1.0)
		return
	if _waiting.has(_state.active_builder_id):
		_retry_builder_route(builder)
		return
	if row > 0 and lift.fsm_state == &"idle" and _miner_at_lift() and _state.lift_operator_id() == -1:
		_start_manual_lift(Owner.MINER)
	if builder.fsm_state != &"idle":
		return

	# Clear bricks already at the platform or lift base, including those in old saves.
	var source := Owner.FINISHED if row == 0 and _state.stock_count(Owner.PLATFORM) == 0 else Owner.PLATFORM
	if source == Owner.PLATFORM and _state.stock_count(source) > 0 \
			and not builder.position.is_equal_approx(_landing()):
		_queue_construction_move(builder, &"join_platform", _landing(), _builder_speed)
		return
	if _take_input(_state.active_builder_id, source):
		_queue_placement()
	elif lift.fsm_state != &"idle" or _state.lift_operator_id() != -1:
		return
	elif row > 0 and (not geometry.has_custom_blueprint() or _state.delivery_point.is_finite()) \
			and _state.stock_count(Owner.FINISHED) > 0 and _state.free_slots(Owner.PLATFORM) > 0:
		_queue_construction_move(builder, &"walk_to_lift", geometry.lift_operator_position(), _builder_speed)
	else:
		if row > 0 and _state.free_slots(Owner.FINISHED) == 0:
			return
		var brick: int = _state.placed_count() if _state.geometry.has_custom_blueprint() else _state.stock(Owner.WORKSHOP_OUTPUT).front() if not _state.stock(Owner.WORKSHOP_OUTPUT).is_empty() else -1
		if brick in _state.stock(Owner.WORKSHOP_OUTPUT) \
				and _state.reserve_transfer(_state.active_builder_id, [brick], Owner.WORKSHOP_OUTPUT):
			_queue_construction_move(builder, &"walk_to_workshop", geometry.workshop_pickup(), _builder_speed)


func assign_assistance() -> void:
	# Each custom block gets a landing selected from its own placed geometry.
	if _state.geometry.has_custom_blueprint():
		return
	var row := _state.current_row
	var builder := _state.worker(_state.active_builder_id)
	if row == 0 or _state.completed_rows > row \
			or builder.fsm_state not in [&"walk_to_brick", &"place_brick", &"return_to_platform"]:
		return
	if _miner_at_lift() or _state.stock_count(Owner.FINISHED) == 0 or _state.free_slots(Owner.PLATFORM) <= 0 \
			or _state.worker(Owner.LIFT).fsm_state != &"idle" or _state.lift_operator_id() != -1:
		return
	var geometry := _state.geometry
	var remaining := geometry.row_size(row) - (_state.placed_count() - _state.row_start) - _state.stock_count(_state.active_builder_id)
	if _state.stock_count(Owner.PLATFORM) >= remaining:
		return

	# Choose the idle worker who can reach the crank first.
	var best: State.Worker
	var best_route := PackedVector2Array()
	var best_time := INF
	if _state.stock_count(Owner.PLATFORM) == 0:
		# Avoid sending help that would reach the crank after the builder.
		var builder_distance := builder.position.distance_to(_landing()) \
			+ geometry.route_length(geometry.platform_to_lift_operator(row))
		best_time = builder_distance / (_builder_speed * builder.speed_multiplier)
		match builder.fsm_state:
			&"walk_to_brick":
				best_time += _place_seconds / builder.speed_multiplier
			&"place_brick":
				best_time += builder.remaining_work / builder.speed_multiplier
	for id in _state.worker_ids():
		var worker := _state.worker(id)
		if worker.role in [State.Worker.Role.BUILDER, State.Worker.Role.LIFT] \
				or (worker.role == State.Worker.Role.MINER and id != Owner.MINER) \
				or (worker.role == State.Worker.Role.DRESSER and id != Owner.DRESSER):
			continue
		var available := &"exhausted" if id == Owner.MINER else &"idle"
		if worker.fsm_state != available:
			continue
		var speed := _helper_speed(worker) * worker.speed_multiplier
		if not is_finite(speed) or speed <= 0.0:
			continue
		var route := _helper_lift_route(worker)
		if route.is_empty():
			continue
		var travel_time := geometry.route_length(route) / speed
		if travel_time < best_time or (best != null and travel_time == best_time and id < best.id):
			best = worker
			best_route = route
			best_time = travel_time
	if best != null:
		best.queue_move(&"walk_to_lift", best_route, _helper_speed(best))


func _helper_lift_route(worker: State.Worker) -> PackedVector2Array:
	var geometry := _state.geometry
	if worker.id == Owner.MINER:
		return geometry.miner_to_lift_operator()
	return _construction_route(worker.position, geometry.lift_operator_position())


func _helper_speed(worker: State.Worker) -> float:
	match worker.id:
		Owner.MINER: return _miner_speed
		Owner.DRESSER: return _dresser_speed
	return _porter_speed


func _miner_at_lift() -> bool:
	var miner := _state.worker(Owner.MINER)
	return miner.position == _state.geometry.lift_operator_position() \
		and miner.fsm_state in [&"idle", &"exhausted", &"operate_lift"] \
		and _state.mined_count() == State.RESOURCE_COUNT


func _pick_up_at_workshop() -> void:
	var pending := _state.task_resource_ids(_state.active_builder_id)
	if pending.is_empty() or not _state.pick_up(_state.active_builder_id, pending[0]):
		return
	var geometry := _state.geometry
	if _state.current_row == 0:
		_queue_placement()
		return
	var builder := _state.worker(_state.active_builder_id)
	var base := geometry.finished_storage()
	_queue_construction_move(builder, &"walk_to_lift_base", base,
		_builder_speed / geometry.block_multiplier(_state.placed_count()))


func _after_builder_unload() -> void:
	var builder := _state.worker(_state.active_builder_id)
	var geometry := _state.geometry
	if _miner_at_lift():
		_queue_construction_move(builder, &"return_from_lift",
			_landing(), _builder_speed)
	else:
		_queue_construction_move(builder, &"walk_to_lift",
			geometry.lift_operator_position(), _builder_speed)


func _queue_placement() -> void:
	var builder := _state.worker(_state.active_builder_id)
	if _queue_construction_move(builder, &"walk_to_brick", _placement_point(),
			_builder_speed / _state.geometry.block_multiplier(_state.placed_count())):
		builder.queue_work(&"place_brick", _place_seconds, 1.0)


func _start_manual_lift(operator_id: int) -> void:
	var geometry := _state.geometry
	var row := _state.current_row
	var operator := _state.worker(operator_id)
	var lift := _state.worker(Owner.LIFT)
	var builder := _state.worker(_state.active_builder_id)
	if _state.completed_rows == row and builder.fsm_state not in [&"rebuild_platform", &"climb_to_platform"] \
			and lift.fsm_state == &"idle" \
			and (not geometry.has_custom_blueprint() or _state.delivery_point.is_finite()) \
			and _take_input(Owner.LIFT, Owner.FINISHED):
		var route := geometry.lift_route(row, _landing())
		var duration := geometry.lift_seconds(row) * geometry.block_multiplier(_state.placed_count())
		lift.position = route[0]
		lift.queue_move(&"lift_brick", route, geometry.route_length(route) / duration)
		operator.queue_work(&"operate_lift", duration, 1.0)
	if operator_id == Owner.MINER:
		return
	var is_builder := operator_id == _state.active_builder_id
	if is_builder:
		_queue_construction_move(operator, &"return_from_lift", _landing(), _builder_speed)
	else:
		var destination := geometry.workshop() if operator.role == State.Worker.Role.DRESSER else geometry.raw_storage()
		_queue_construction_move(operator, &"return_from_lift", destination, _helper_speed(operator))


func _take_input(worker_id: int, source: int, resource_id: int = -1) -> bool:
	var stock := _state.stock(source)
	if stock.is_empty():
		return false
	if resource_id < 0:
		resource_id = _state.placed_count() if _state.geometry.has_custom_blueprint() else stock[0]
	if resource_id not in stock:
		return false
	if not _state.reserve_transfer(worker_id, [resource_id], source):
		return false
	if _state.pick_up(worker_id, resource_id):
		return true
	_state.cancel_transfer(worker_id)
	return false


func _next_raw_resource() -> int:
	if not _state.geometry.has_custom_blueprint():
		var raw := _state.stock(Owner.RAW)
		if not raw.is_empty():
			return raw[0]
		var quarry_stock := _state.stock(Owner.QUARRY_STOCK)
		for resource_id: int in quarry_stock:
			if _state.reserved_by(resource_id) == -1:
				return resource_id
		return -1
	for resource_id in range(_state.placed_count(), _state.target_count()):
		var owner := _state.owner_of(resource_id)
		if owner in [Owner.RAW, Owner.QUARRY_STOCK]:
			return resource_id if _state.reserved_by(resource_id) == -1 else -1
		if owner in [Owner.UNMINED, Owner.QUARRY] \
				or owner in _state.worker_ids_for_role(State.Worker.Role.MINER) \
				or owner in _state.worker_ids_for_role(State.Worker.Role.PORTER):
			return -1
	return -1


func _deliver(worker_id: int) -> bool:
	var pending := _state.task_resource_ids(worker_id)
	return not pending.is_empty() and _state.deliver(worker_id, pending[0])


func _refresh_routes() -> void:
	var revision := _state.placed_count()
	if revision == _route_revision and _route_row == _state.current_row:
		return
	var geometry := _state.geometry
	# Custom decks follow the highest masonry to their left. A local edit can
	# shift their height and connections farther away than the changed block.
	var incremental := not geometry.has_custom_blueprint() \
		and revision == _route_revision + 1 and _route_row == _state.current_row
	var previous := _scaffolds.duplicate() if incremental else []
	_route_revision = revision
	_route_row = _state.current_row
	_route_generation += 1
	_placed_snapshot = _state.placed_surface_snapshot()
	_scaffolds.clear()
	var unit := geometry.brick_size()
	_change_x0 = -INF
	_change_x1 = INF
	if incremental:
		for block: Dictionary in _placed_snapshot.blocks:
			if int(block.id) != revision - 1:
				continue
			_change_x0 = float(block.x0) - 8.0 * unit.x
			_change_x1 = float(block.x1) + 8.0 * unit.x
			break
		var column := revision - _state.row_start
		if column >= 0 and column < geometry.row_size(_state.current_row):
			var origin: Vector2 = geometry.brick_origin(_state.current_row, column)
			var extent: Vector2 = geometry.brick_extent(_state.current_row, column)
			_change_x0 = minf(_change_x0, origin.x - 8.0 * unit.x)
			_change_x1 = maxf(_change_x1, origin.x + extent.x + 8.0 * unit.x)
		for scaffold: Dictionary in previous:
			if not _scaffold_touches_change(scaffold):
				_scaffolds.append(scaffold)
	var settings := _scaffold_settings()
	if geometry.has_custom_blueprint():
		_build_custom_row_scaffold(settings, revision)
		_dedupe_scaffolds()
		_state.scaffold_sections = _scaffolds.duplicate(true)
		if _state.current_row > 0 and _state.stock_count(Owner.PLATFORM) == 0 \
				and _state.worker(Owner.LIFT).fsm_state == &"idle":
			_delivery_attempt_generation = _route_generation
			_delivery_attempt_phase = _state.worker(_state.active_builder_id).fsm_state
			_state.delivery_point = _choose_delivery_point()
		return
	var left_edges := {}
	var right_edges := {}
	for block: Dictionary in _placed_snapshot.blocks:
		left_edges[Vector2(block.x0, block.y1)] = true
		right_edges[Vector2(block.x1, block.y1)] = true
	for block: Dictionary in _placed_snapshot.blocks:
		if not _in_changed_band(float(block.x0), float(block.x1)):
			continue
		for side in [-1, 1]:
			var edge: float = block.x0 if side < 0 else block.x1
			if (side < 0 and right_edges.has(Vector2(edge, block.y1))) \
					or (side > 0 and left_edges.has(Vector2(edge, block.y1))):
				continue
			# Vector2 rounds to float32; stay just above the exact block top.
			var deck_y := float(block.y1) + 0.000001
			var work := Vector2(edge - side * 0.25 * unit.x, deck_y)
			for approach in [1.0, 0.75, 0.5, 0.25]:
				var outside := Vector2(edge + side * approach * unit.x, deck_y)
				var support := geometry.support_below(_placed_snapshot, outside)
				if support.is_empty() or is_equal_approx(float(support.y), float(block.y1)):
					continue
				var landing := Vector2(outside.x, float(support.y))
				var section := geometry.scaffold_snapshot(_placed_snapshot, landing, work, settings)
				if not section.ok and side < 0:
					section = geometry.scaffold_snapshot(_placed_snapshot,
						landing, Vector2(edge, deck_y), settings)
				if section.ok:
					_scaffolds.append(section)
					break
	var surfaces: Array = _placed_snapshot.surfaces.duplicate()
	surfaces.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.y < b.y if a.y != b.y else a.x0 < b.x0)
	for i in range(1, surfaces.size()):
		var left: Dictionary = surfaces[i - 1]
		var right: Dictionary = surfaces[i]
		if left.y <= 0.0 or not is_equal_approx(float(left.y), float(right.y)) \
				or right.x0 <= left.x1 + 0.00001:
			continue
		var start := Vector2(left.x1, left.y)
		var finish := Vector2(right.x0, right.y)
		if not _in_changed_band(start.x, finish.x):
			continue
		if not geometry._scaffold_clear_segment(_placed_snapshot, start, finish,
				0.18 * unit.x, 0.9 * unit.y, 0.02 * unit.y):
			continue
		var bridge := geometry.scaffold_run_snapshot(_placed_snapshot, start, finish, settings)
		if bridge.ok:
			_scaffolds.append(bridge)
	for row in [maxi(0, _state.current_row - 1), _state.current_row, _state.current_row + 1]:
		if row >= geometry.row_count():
			continue
		var platform: Vector2 = geometry.platform(row)
		var support := geometry.support_below(_placed_snapshot, platform)
		if support.is_empty() or is_equal_approx(float(support.y), platform.y):
			continue
		var landing := Vector2(platform.x, float(support.y))
		var section := geometry.scaffold_snapshot(_placed_snapshot, landing, platform, settings)
		if section.ok:
			_scaffolds.append(section)
	_dedupe_scaffolds()
	_state.scaffold_sections = _scaffolds.duplicate(true)
	for surface: Dictionary in surfaces:
		if surface.y <= 0.0:
			continue
		_state.scaffold_sections.append({"ok": true, "reason": "", "sections": [{
			"id": "surface-deck:%s" % surface.id, "x0": surface.x0,
			"x1": surface.x1, "y": surface.y, "post_ids": []}],
			"posts": [], "transitions": []})


func _in_changed_band(x0: float, x1: float) -> bool:
	return x1 >= _change_x0 and x0 <= _change_x1


func _scaffold_settings() -> Dictionary:
	var unit := _state.geometry.brick_size()
	return {"section_width": 1.5 * unit.x, "max_span": 2.0 * unit.x,
		"max_void_width": 2.0 * unit.x, "max_void_depth": 5.0 * unit.y,
		"max_post_height": 5.0 * unit.y, "max_transition_rise": 5.0 * unit.y}


func _scaffold_touches_change(scaffold: Dictionary) -> bool:
	for section: Dictionary in scaffold.sections:
		if _in_changed_band(float(section.x0), float(section.x1)):
			return true
	for post: Dictionary in scaffold.posts:
		if _in_changed_band(float(post.x0), float(post.x1)):
			return true
	for transition: Dictionary in scaffold.transitions:
		if _in_changed_band(minf(transition["from"].x, transition["to"].x),
				maxf(transition["from"].x, transition["to"].x)):
			return true
	return false


func _dedupe_scaffolds() -> void:
	var seen := {}
	var unique := []
	for scaffold: Dictionary in _scaffolds:
		var ids: Array[String] = []
		for section: Dictionary in scaffold.sections:
			ids.append(str(section.id))
		for transition: Dictionary in scaffold.transitions:
			ids.append(str(transition.id))
		var key := "|".join(ids)
		if not seen.has(key):
			seen[key] = true
			unique.append(scaffold)
	_scaffolds = unique


func _build_custom_row_scaffold(settings: Dictionary, placement_index: int) -> void:
	var geometry := _state.geometry
	var unit := geometry.brick_size()
	var floor_y := geometry.stage_height(_state.current_row)
	var builder := _state.worker(_state.active_builder_id)
	if _state.current_row > 0 and placement_index == _state.row_start \
			and builder.fsm_state == &"idle" and builder.position.y > 0.0 and builder.position.y < floor_y:
		floor_y = geometry.stage_height(_state.current_row - 1)
	var blocks: Array = _placed_snapshot.blocks.duplicate()
	if blocks.is_empty():
		return
	blocks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.x0 < b.x0 if a.x0 != b.x0 else a.y1 < b.y1)
	var left := float(blocks[0].x0) - unit.x
	var right := float(blocks[0].x1)
	var target_origin := Vector2.INF
	var target_extent := Vector2.ZERO
	var work_x := NAN
	var cuts: Array[float] = [left]
	for block: Dictionary in blocks:
		cuts.append(float(block.x0))
		cuts.append(float(block.x1))
		right = maxf(right, float(block.x1))
	if placement_index < _state.target_count() \
			and placement_index - _state.row_start < geometry.row_size(_state.current_row):
		var column := placement_index - _state.row_start
		target_origin = geometry.brick_origin(_state.current_row, column)
		target_extent = geometry.brick_extent(_state.current_row, column)
		work_x = target_origin.x - 0.25 * unit.x
		cuts.append(work_x)
		var masonry_right := right
		right = work_x
		# A row can start to the left of the builder or a delivery still on the old deck.
		if builder.position.y > 0.0:
			right = maxf(right, minf(builder.position.x + unit.x, masonry_right))
		if _state.delivery_point.is_finite() and _state.delivery_point.y > 0.0:
			right = maxf(right, minf(_state.delivery_point.x + unit.x, masonry_right))
	cuts.append(right)
	cuts.sort()
	var unique_cuts: Array[float] = []
	for cut in cuts:
		if cut < left - 0.00001 or cut > right + 0.00001:
			continue
		if unique_cuts.is_empty() or not is_equal_approx(unique_cuts[-1], cut):
			unique_cuts.append(cut)
	var deck_runs: Array[Dictionary] = []
	for index in range(1, unique_cuts.size()):
		var x0 := unique_cuts[index - 1]
		var x1 := unique_cuts[index]
		if x1 <= x0 + 0.00001:
			continue
		var y := _custom_deck_height((x0 + x1) * 0.5, floor_y)
		var run_finish := x1
		if _custom_deck_height(x1 + 0.0001 * unit.x, floor_y) > y + 0.00001:
			run_finish -= 0.5 * float(settings.get("worker_width", 0.18 * unit.x)) + 0.00001
		if run_finish <= x0 + 0.00001:
			continue
		if not deck_runs.is_empty() and is_equal_approx(float(deck_runs[-1].y), y) \
				and is_equal_approx(float(deck_runs[-1].x1), x0):
			deck_runs[-1].x1 = run_finish
		else:
			deck_runs.append({"x0": x0, "x1": run_finish, "y": y})
	var run_settings := settings.duplicate()
	run_settings.max_span = 4.0 * unit.x
	for deck: Dictionary in deck_runs:
		var run: Dictionary = geometry.scaffold_run_snapshot(_placed_snapshot,
			Vector2(deck.x0, deck.y), Vector2(deck.x1, deck.y), run_settings)
		if run.ok:
			_scaffolds.append(run)
			continue
		# One unsupported end must not remove the usable part of a long deck.
		var previous_start := -INF
		var previous_end := -INF
		for index in range(1, unique_cuts.size()):
			var x0 := maxf(deck.x0, unique_cuts[index - 1])
			var x1 := minf(deck.x1, unique_cuts[index])
			if x1 - x0 < 0.2 * unit.x:
				continue
			var supported_run: Dictionary = geometry.scaffold_run_snapshot(_placed_snapshot,
				Vector2(x0, deck.y), Vector2(x1, deck.y), run_settings)
			if not supported_run.ok:
				continue
			var gap := x0 - previous_end
			if gap > 0.00001 and gap <= float(settings.max_void_width):
				var bridge := geometry.scaffold_run_snapshot(_placed_snapshot,
					Vector2(maxf(previous_start, previous_end - 0.25 * unit.x), deck.y),
					Vector2(minf(x1, x0 + 0.25 * unit.x), deck.y), run_settings)
				if bridge.ok:
					_scaffolds.append(bridge)
			_scaffolds.append(supported_run)
			previous_start = x0
			previous_end = x1
	if floor_y > 0.0:
		var entry := geometry.scaffold_snapshot(_placed_snapshot,
			Vector2(left - unit.x, 0.0), Vector2(left, floor_y), settings)
		if entry.ok:
			_scaffolds.append(entry)
	if target_origin.is_finite():
		_append_right_approach(target_origin, target_extent, settings, run_settings)
	if placement_index > _state.row_start:
		# The last approach is still needed by a worker leaving the new block.
		var previous_column := placement_index - _state.row_start - 1
		_append_right_approach(geometry.brick_origin(_state.current_row, previous_column),
			geometry.brick_extent(_state.current_row, previous_column), settings, run_settings)
	for block: Dictionary in blocks:
		if float(block.x0) > right + 0.00001:
			continue
		var before := _custom_deck_height(float(block.x0) - 0.0001 * unit.x, floor_y)
		var top := maxf(before, float(block.y1))
		if top <= before + 0.00001:
			continue
		var work := Vector2(float(block.x0) + 0.25 * unit.x, top)
		for approach in [1.5, 1.25, 1.0, 0.75, 0.5]:
			var landing := Vector2(float(block.x0) - approach * unit.x, before)
			var rise: Dictionary = geometry.scaffold_snapshot(
				_placed_snapshot, landing, work, settings)
			if rise.ok:
				_scaffolds.append(rise)
				break
	_append_corner_routes(settings, floor_y)
	_append_delivery_bridge(settings)


func _append_right_approach(origin: Vector2, extent: Vector2, settings: Dictionary,
		run_settings: Dictionary) -> void:
	var geometry := _state.geometry
	var unit := geometry.brick_size()
	var work_x := origin.x + extent.x + 0.25 * unit.x
	var far_x := work_x + 1.5 * unit.x
	var run := geometry.scaffold_run_snapshot(_placed_snapshot,
		Vector2(work_x, origin.y), Vector2(far_x, origin.y), run_settings)
	if run.ok:
		_scaffolds.append(run)
	if origin.y > 0.0:
		var entry := geometry.scaffold_snapshot(_placed_snapshot,
			Vector2(far_x + unit.x, 0.0), Vector2(far_x, origin.y), settings)
		if entry.ok:
			_scaffolds.append(entry)


func _append_delivery_bridge(settings: Dictionary) -> void:
	var builder := _state.worker(_state.active_builder_id)
	var landing := _state.delivery_point if _state.delivery_point.is_finite() else builder.position
	var active_route := builder.movement_route()
	if not _state.delivery_point.is_finite() and builder.fsm_state in [
			&"join_platform", &"climb_to_platform"] and not active_route.is_empty():
		landing = active_route[-1]
	if landing.y <= 0.0:
		return
	var geometry := _state.geometry
	var best := Vector2.INF
	for surface: Dictionary in _placed_snapshot.surfaces:
		if str(surface.source) != "block" or not is_equal_approx(float(surface.y), landing.y):
			continue
		if landing.x >= surface.x0 and landing.x <= surface.x1:
			return
		var edge := Vector2(float(surface.x1) if landing.x > surface.x1 else float(surface.x0), landing.y)
		if not best.is_finite() or edge.distance_to(landing) < best.distance_to(landing):
			best = edge
	if not best.is_finite():
		_append_held_landing(landing, settings)
		return
	var bridge := geometry.scaffold_run_snapshot(_placed_snapshot,
		Vector2(minf(best.x, landing.x), landing.y),
		Vector2(maxf(best.x, landing.x), landing.y), settings)
	if bridge.ok:
		_scaffolds.append(bridge)


func _append_held_landing(landing: Vector2, settings: Dictionary) -> void:
	var geometry := _state.geometry
	var unit := geometry.brick_size()
	var edge := Vector2.INF
	for surface: Dictionary in _placed_snapshot.surfaces:
		if str(surface.source) != "block" or float(surface.y) <= landing.y:
			continue
		var x: float = float(surface.x1) if landing.x > surface.x1 else float(surface.x0)
		if not is_finite(x):
			continue
		var candidate := Vector2(x, float(surface.y))
		if not edge.is_finite() or absf(candidate.x - landing.x) < absf(edge.x - landing.x):
			edge = candidate
	if not edge.is_finite():
		return
	var direction := 1.0 if landing.x > edge.x else -1.0
	var high_inner := Vector2(edge.x - direction * 0.5 * unit.x, edge.y)
	var high_outer := Vector2(edge.x + direction * 0.5 * unit.x, edge.y)
	var low_outer := Vector2(high_outer.x + direction * maxf(unit.x,
		(edge.y - landing.y) * 1.3), landing.y)
	var high_deck := geometry.scaffold_run_snapshot(_placed_snapshot,
		Vector2(minf(high_inner.x, high_outer.x), edge.y),
		Vector2(maxf(high_inner.x, high_outer.x), edge.y), settings)
	var low_deck := geometry.scaffold_run_snapshot(_placed_snapshot,
		Vector2(minf(landing.x, low_outer.x), landing.y),
		Vector2(maxf(landing.x, low_outer.x), landing.y), settings)
	if not high_deck.ok or not low_deck.ok \
			or not geometry._scaffold_clear_segment(_placed_snapshot, high_outer,
				low_outer, 0.18 * unit.x, 0.9 * unit.y, 0.02 * unit.y):
		return
	_scaffolds.append(high_deck)
	_scaffolds.append(low_deck)
	_scaffolds.append({"ok": true, "reason": "", "sections": [], "posts": [],
		"transitions": [{"id": "held:%0.4f:%0.4f" % [landing.x, landing.y],
			"from": high_outer, "to": low_outer, "kind": "slope"}]})


func _append_corner_routes(settings: Dictionary, floor_y: float) -> void:
	var geometry := _state.geometry
	var edges := {}
	for surface: Dictionary in _placed_snapshot.surfaces:
		if str(surface.source) == "block":
			var deck: Dictionary = geometry.scaffold_run_snapshot(_placed_snapshot,
				Vector2(surface.x0, surface.y), Vector2(surface.x1, surface.y), settings)
			if deck.ok:
				_scaffolds.append(deck)
		for side in ["x0", "x1"]:
			var x: float = float(surface[side])
			if is_inf(x):
				continue
			var key := "%0.5f" % x
			if not edges.has(key):
				edges[key] = {"left": [], "right": []}
			edges[key]["right" if side == "x0" else "left"].append(surface)
	var deck_sections: Array[Dictionary] = []
	for scaffold: Dictionary in _scaffolds:
		deck_sections.append_array(scaffold.sections)
	for key in edges:
		var sides: Dictionary = edges[key]
		for left_surface: Dictionary in sides.left:
			for right_surface: Dictionary in sides.right:
				if is_equal_approx(float(left_surface.y), float(right_surface.y)):
					continue
				var high: Dictionary = left_surface if left_surface.y > right_surface.y else right_surface
				var low: Dictionary = right_surface if left_surface.y > right_surface.y else left_surface
				var edge_x := float(key)
				var direction := 1.0 if high == left_surface else -1.0
				_append_covered_deck_link(edge_x, direction, high, settings, deck_sections)
				if _append_corner_route(edge_x, direction, high.y, low.y, settings):
					continue
				_append_corner_to_raised_deck(edge_x, direction, high.y, low.y, settings, deck_sections)
				_append_recess_approach(edge_x, direction, high.y, maxf(low.y, floor_y), settings)
	_append_gap_slopes(edges, settings, deck_sections)


func _append_gap_slopes(edges: Dictionary, settings: Dictionary,
		deck_sections: Array[Dictionary]) -> void:
	var geometry := _state.geometry
	var unit := geometry.brick_size()
	var ordered := edges.keys()
	ordered.sort_custom(func(a: String, b: String) -> bool: return float(a) < float(b))
	for index in range(ordered.size()):
		var left_x := float(ordered[index])
		var left_y := _highest_block_top(edges[ordered[index]].left)
		if not is_finite(left_y):
			continue
		for right_index in range(index + 1, ordered.size()):
			var right_x := float(ordered[right_index])
			if right_x - left_x > float(settings.max_void_width) + 0.00001:
				break
			var right_y := _highest_block_top(edges[ordered[right_index]].right)
			var rise := absf(left_y - right_y)
			if not is_finite(right_y) or rise <= 0.00001 or rise > float(settings.max_transition_rise):
				continue
			var direction := 1.0 if left_y > right_y else -1.0
			var high_x := left_x if direction > 0.0 else right_x
			var high := Vector2(high_x + direction * 0.11 * unit.x, maxf(left_y, right_y))
			var low_x := right_x if direction > 0.0 else left_x
			var low := Vector2(low_x + direction * 0.25 * unit.x, minf(left_y, right_y))
			if not deck_sections.any(func(section: Dictionary) -> bool: return Routes._on_walk(section, low)):
				continue
			if high.distance_to(low) > 5.0 * unit.x \
					or not geometry._scaffold_clear_segment(_placed_snapshot, high, low,
						0.18 * unit.x, 0.9 * unit.y, 0.02 * unit.y):
				continue
			var inner := high_x - direction * 0.5 * unit.x
			var landing := geometry.scaffold_run_snapshot(_placed_snapshot,
				Vector2(minf(high.x, inner), high.y), Vector2(maxf(high.x, inner), high.y), settings)
			if not landing.ok:
				continue
			var id := "gap-slope:%0.4f:%0.4f:%0.4f:%0.4f" % [high.x, high.y, low.x, low.y]
			landing.transitions.append({"id": id, "from": high, "to": low, "kind": "slope"})
			_scaffolds.append(landing)
			break


func _highest_block_top(surfaces: Array) -> float:
	var height := -INF
	for surface: Dictionary in surfaces:
		if str(surface.source) == "block":
			height = maxf(height, float(surface.y))
	return height


func _append_corner_to_raised_deck(edge_x: float, direction: float, high_y: float,
		low_y: float, settings: Dictionary, deck_sections: Array[Dictionary]) -> void:
	var unit_x := _state.geometry.brick_size().x
	var heights: Array[float] = []
	# The adjacent block can be too low to support a clear run across the next block.
	# A raised deck already crossing that side can provide a landing.
	for section in deck_sections:
		var y := float(section.y)
		if y <= low_y + 0.00001 or y >= high_y - 0.00001 or heights.has(y):
			continue
		var landing_x := _corner_slope_end_x(edge_x, direction, high_y - y, unit_x)
		if landing_x >= float(section.x0) - 0.00001 and landing_x <= float(section.x1) + 0.00001:
			heights.append(y)
	heights.sort()
	for y in heights:
		if _append_corner_route(edge_x, direction, high_y, y, settings):
			return


func _append_covered_deck_link(edge_x: float, direction: float, surface: Dictionary,
		settings: Dictionary, deck_sections: Array[Dictionary]) -> void:
	var geometry := _state.geometry
	var unit := geometry.brick_size()
	var low := Vector2(edge_x - direction * 0.25 * unit.x, surface.y)
	if low.x < surface.x0 or low.x > surface.x1:
		return
	if not deck_sections.any(func(section: Dictionary) -> bool: return Routes._on_walk(section, low)):
		return
	for section in deck_sections:
		var rise := float(section.y) - low.y
		if rise <= 0.00001 or rise > float(settings.max_transition_rise):
			continue
		var run := maxf(unit.x, 2.0 * rise)
		for fraction in [1.0, 0.75, 0.5]:
			var high := Vector2(low.x - direction * run * fraction, section.y)
			if not Routes._on_walk(section, high):
				continue
			if not geometry._scaffold_clear_segment(_placed_snapshot, high, low,
					0.18 * unit.x, 0.9 * unit.y, 0.02 * unit.y):
				continue
			var id := "covered:%0.4f:%0.4f:%0.4f:%d" % [edge_x, high.y, low.y, int(direction)]
			_scaffolds.append({"ok": true, "reason": "", "sections": [], "posts": [],
				"transitions": [{"id": id, "from": high, "to": low, "kind": "slope"}]})
			return


func _append_recess_approach(edge_x: float, direction: float, high_y: float,
		low_y: float, settings: Dictionary) -> void:
	var geometry := _state.geometry
	var unit := geometry.brick_size()
	var rise := high_y - low_y
	if rise <= 0.00001 or rise > float(settings.max_transition_rise):
		return
	var inset := 0.11 * unit.x
	var upper := Vector2(edge_x + direction * inset, high_y)
	var inner := edge_x - direction * 0.5 * unit.x
	var top := geometry.scaffold_run_snapshot(_placed_snapshot,
		Vector2(minf(inner, upper.x), high_y), Vector2(maxf(inner, upper.x), high_y), settings)
	if not top.ok:
		return
	var foot := Vector2(upper.x, low_y)
	for span in [4.0, 3.0, 2.0, 1.0]:
		var lower := Vector2(edge_x + direction * (span * unit.x - inset), low_y)
		var recess := geometry.scaffold_run_snapshot(_placed_snapshot,
			Vector2(minf(foot.x, lower.x), low_y), Vector2(maxf(foot.x, lower.x), low_y), settings)
		if not recess.ok or upper.distance_to(lower) > 5.0 * unit.x \
				or not geometry._scaffold_clear_segment(_placed_snapshot, upper, lower,
					0.18 * unit.x, 0.9 * unit.y, 0.02 * unit.y):
			continue
		_scaffolds.append(top)
		_scaffolds.append(recess)
		var id := "recess:%0.4f:%0.4f:%0.4f:%d" % [edge_x, high_y, low_y, int(direction)]
		_scaffolds.append({"ok": true, "reason": "", "sections": [], "posts": [],
			"transitions": [{"id": id, "from": upper, "to": lower, "kind": "slope"}]})
		return


func _corner_slope_end_x(edge_x: float, direction: float, rise: float, unit_x: float) -> float:
	return edge_x + direction * (0.5 * unit_x + maxf(unit_x, rise * 2.0))


func _append_corner_route(edge_x: float, direction: float, high_y: float,
		low_y: float, settings: Dictionary) -> bool:
	var geometry := _state.geometry
	var unit := geometry.brick_size()
	var offset := 0.5 * unit.x
	var high_inner := Vector2(edge_x - direction * offset, high_y)
	var high_outer := Vector2(edge_x + direction * offset, high_y)
	var low_inner := Vector2(edge_x + direction * 0.11 * unit.x, low_y)
	var low_outer := Vector2(_corner_slope_end_x(edge_x, direction, high_y - low_y, unit.x), low_y)
	var high_deck := geometry.scaffold_run_snapshot(_placed_snapshot,
		Vector2(minf(high_inner.x, high_outer.x), high_y),
		Vector2(maxf(high_inner.x, high_outer.x), high_y), settings)
	if not high_deck.ok:
		return false
	var low_deck := {"ok": true}
	if low_y > 0.0:
		low_deck = geometry.scaffold_run_snapshot(_placed_snapshot,
			Vector2(minf(low_inner.x, low_outer.x), low_y),
			Vector2(maxf(low_inner.x, low_outer.x), low_y), settings)
	if not low_deck.ok or not geometry._scaffold_clear_segment(_placed_snapshot,
			high_outer, low_outer, 0.18 * unit.x, 0.9 * unit.y, 0.02 * unit.y):
		return false
	var id := "corner:%0.4f:%0.4f:%0.4f" % [edge_x, high_y, low_y]
	_scaffolds.append(high_deck)
	if low_y > 0.0:
		_scaffolds.append(low_deck)
	_scaffolds.append({"ok": true, "reason": "", "sections": [], "posts": [],
		"transitions": [{"id": id, "from": high_outer, "to": low_outer,
			"kind": "slope"}]})
	return true
func _custom_deck_height(x: float, floor_y: float) -> float:
	var height := floor_y
	for block: Dictionary in _placed_snapshot.blocks:
		if float(block.x0) <= x + 0.00001:
			height = maxf(height, float(block.y1))
	return height


func _landing() -> Vector2:
	_refresh_routes()
	return _state.platform_position()


func _choose_delivery_point() -> Vector2:
	var geometry := _state.geometry
	if _state.placed_count() >= _state.target_count() \
			or _state.placed_count() - _state.row_start >= geometry.row_size(_state.current_row):
		return Vector2.INF
	var target := _placement_point()
	if not target.is_finite():
		return Vector2.INF
	# Custom work points already lie on a reachable deck. The same point
	# minimizes the distance from the landing to the work.
	if geometry.has_custom_blueprint() and target.y > 0.0:
		return target
	var best := Vector2.INF
	var best_score := INF
	var builder := _state.worker(_state.active_builder_id)
	var route_settings := {"include_surfaces": false} if geometry.has_custom_blueprint() else {}
	for scaffold: Dictionary in _state.scaffold_sections:
		for section: Dictionary in scaffold.sections:
			var x := clampf(target.x, float(section.x0), float(section.x1))
			var candidate := Vector2(x, float(section.y))
			if candidate.y <= 0.0:
				continue
			var to_work := Routes.find_path(geometry, _placed_snapshot,
				_scaffolds, candidate, target, route_settings)
			if not to_work.ok:
				continue
			var to_pickup := Routes.find_path(geometry, _placed_snapshot,
				_scaffolds, builder.position, candidate, route_settings)
			if not to_pickup.ok:
				continue
			var score := float(to_work.length) + candidate.distance_to(target) * 0.01
			if score < best_score:
				best = candidate
				best_score = score
	return best


func waiting_snapshot() -> Dictionary:
	var result := {}
	for id in _waiting:
		result[str(id)] = String(_waiting[id])
	return result


func blocked_snapshot() -> Dictionary:
	var result := {}
	var builder := _state.worker(_state.active_builder_id)
	var block_id := _state.placed_count()
	var column := block_id - _state.row_start
	var target := {}
	if block_id < _state.target_count() and column >= 0 \
			and column < _state.geometry.row_size(_state.current_row):
		var block: Dictionary = _state.geometry.block_for_placement(block_id)
		target = {"id": block_id, "x": block.x, "y": block.y, "size": block.size}
	for id in _waiting:
		result[str(id)] = {"phase": String(_waiting[id]), "target": target if id == builder.id else {},
			"reason": _waiting_reason.get(id, "route_unavailable")}
	if not target.is_empty() and _state.geometry.has_custom_blueprint() \
			and _state.current_row > 0 and _state.completed_rows == _state.current_row \
			and builder.fsm_state == &"idle" and not _waiting.has(builder.id) \
			and _state.stock_count(Owner.FINISHED) > 0 and _state.stock_count(Owner.PLATFORM) == 0 \
			and _state.worker(Owner.LIFT).fsm_state == &"idle" and not _state.delivery_point.is_finite():
		result[str(builder.id)] = {"phase": "choose_delivery_point", "target": target,
			"reason": "no_reachable_delivery_point"}
	return result


func _route_stamp() -> int:
	return _route_generation


# Called after GameState has restored masonry, ownership and every worker phase.
func restore_routes(saved_waiting: Variant) -> bool:
	if not saved_waiting is Dictionary:
		return false
	var saved_delivery := _state.delivery_point
	_refresh_routes()
	_state.delivery_point = saved_delivery
	if _state.geometry.has_custom_blueprint() and not _state.delivery_point.is_finite():
		var saved_lift_route := _state.worker(Owner.LIFT).movement_route()
		if not saved_lift_route.is_empty():
			_state.delivery_point = saved_lift_route[-1]
	for key in saved_waiting:
		if not key is String or not key.is_valid_int() or str(int(key)) != key:
			return false
		if not saved_waiting[key] is String:
			return false
		var id := int(key)
		var worker := _state.worker(id)
		var phase := StringName(saved_waiting[key])
		if worker == null or phase not in [&"walk_to_brick", &"return_to_platform",
				&"walk_to_workshop", &"walk_to_lift_base", &"walk_to_lift",
				&"return_from_lift", &"join_platform", &"climb_to_platform"]:
			return false
		if worker.fsm_state != &"idle" and (worker.fsm_state != phase or not worker.route_waiting):
			return false
		_waiting[id] = phase
	# Stage 4 snapshots did not store an idle wait. Recover it from the held
	# transfer, without reserving or moving that resource a second time.
	if saved_waiting.is_empty():
		var builder := _state.worker(_state.active_builder_id)
		if builder.fsm_state == &"idle" and _state.task_resource_ids(builder.id).size() == 1:
			if _state.stock_count(builder.id) == 0 \
					and _state.transfer_source(builder.id) == Owner.WORKSHOP_OUTPUT:
				_waiting[builder.id] = &"walk_to_workshop"
			elif _state.stock_count(builder.id) == 1:
				_waiting[builder.id] = &"walk_to_lift_base" if _state.current_row > 0 \
					and _state.transfer_source(builder.id) == Owner.WORKSHOP_OUTPUT else &"walk_to_brick"
		elif builder.fsm_state == &"idle" and not _state.finished \
				and _state.placed_count() > 0 \
				and not builder.position.is_equal_approx(_landing()):
			_waiting[builder.id] = &"climb_to_platform" if _state.placed_count() == _state.row_start \
				and _state.current_row > 0 else &"return_to_platform"
	_replan_active_moves(true)
	if _state.geometry.has_custom_blueprint() and not saved_delivery.is_finite():
		_route_revision = -1
	return true


func _construction_route(start: Vector2, finish: Vector2) -> PackedVector2Array:
	_refresh_routes()
	if not start.is_finite() or not finish.is_finite():
		_route_failure = "no_safe_work_point"
		return PackedVector2Array()
	var settings := {"include_surfaces": false} if _state.geometry.has_custom_blueprint() else {}
	var found: Dictionary = Routes.find_path(_state.geometry, _placed_snapshot,
		_scaffolds, start, finish, settings)
	_route_failure = str(found.reason)
	return found.points if found.ok else PackedVector2Array()


func _preview_after_scaffolds(after: Dictionary) -> Array:
	var saved_snapshot := _placed_snapshot
	var saved_scaffolds := _scaffolds
	_placed_snapshot = after
	_scaffolds = []
	_build_custom_row_scaffold(_scaffold_settings(), _state.placed_count() + 1)
	_dedupe_scaffolds()
	var preview := _scaffolds
	_placed_snapshot = saved_snapshot
	_scaffolds = saved_scaffolds
	return preview


func _placement_point(start: Variant = null) -> Vector2:
	_refresh_routes()
	var geometry := _state.geometry
	var origin: Vector2 = geometry.brick_origin(_state.current_row,
		_state.placed_count() - _state.row_start)
	var unit := geometry.brick_size()
	var candidate := Vector2(origin.x - 0.25 * unit.x, origin.y)
	if geometry.has_custom_blueprint():
		var route_start: Vector2 = _state.worker(_state.active_builder_id).position \
			if start == null else start
		var after_ids: Array = _state.stock(Owner.PLACED).duplicate()
		after_ids.append(_state.placed_count())
		var after := geometry.placed_surface_snapshot(after_ids)
		var after_scaffolds := _preview_after_scaffolds(after)
		var route_settings := {"include_surfaces": false}
		var ends_row := _state.placed_count() + 1 == _state.row_start + geometry.row_size(_state.current_row)
		var return_to := _first_scaffold_entry() if ends_row else route_start
		if _state.current_row == 0 and is_zero_approx(origin.y):
			var ground_out := Routes.find_path(geometry, _placed_snapshot,
				_scaffolds, route_start, candidate, route_settings)
			var ground_back := Routes.find_path(geometry, after,
				after_scaffolds, candidate, return_to, route_settings)
			if ground_out.ok and ground_back.ok:
				return candidate
		var custom_best := Vector2.INF
		var custom_score := INF
		var best_reach := INF
		var tried := {}
		var extent := geometry.brick_extent(_state.current_row,
			_state.placed_count() - _state.row_start)
		var left_work_x := candidate.x
		var right_work_x := origin.x + extent.x + 0.25 * unit.x
		for scaffold: Dictionary in _scaffolds:
			for section: Dictionary in scaffold.sections:
				if float(section.y) < origin.y - 0.00001 \
						or float(section.y) > origin.y + extent.y + 0.00001:
					continue
				for work_x in [left_work_x, right_work_x]:
					var point := Vector2(clampf(work_x, float(section.x0), float(section.x1)),
						float(section.y))
					if point.x < origin.x - unit.x - 0.00001 \
							or point.x > origin.x + extent.x + unit.x + 0.00001 \
							or (point.x > origin.x and point.x < origin.x + extent.x):
						continue
					# A worker can lay across one open cell when it has no supported deck.
					var reach := 1.0 if point.x < origin.x - 0.75 * unit.x \
						or point.x > origin.x + extent.x + 0.75 * unit.x else 0.75
					if reach > best_reach:
						continue
					if tried.has(point):
						continue
					tried[point] = true
					var offset_cost := minf(absf(point.x - left_work_x), absf(point.x - right_work_x)) \
						+ 10.0 * (point.y - origin.y)
					if reach == best_reach and route_start.distance_to(point) + offset_cost >= custom_score:
						continue
					var outward := Routes.find_path(geometry, _placed_snapshot,
						_scaffolds, route_start, point, route_settings)
					if not outward.ok:
						continue
					var back := Routes.find_path(geometry, after,
						after_scaffolds, point, return_to, route_settings)
					if not back.ok:
						continue
					var score := float(outward.length) + offset_cost
					if reach < best_reach or score < custom_score:
						custom_best = point
						custom_score = score
						best_reach = reach
		return custom_best
	var best := -INF
	for surface: Dictionary in _placed_snapshot.surfaces:
		if float(surface.x0) <= candidate.x and float(surface.x1) >= candidate.x \
				and float(surface.y) <= origin.y + unit.y * 4.0 \
				and float(surface.y) > best:
			best = float(surface.y)
	if is_finite(best):
		candidate.y = best
	return candidate


func _queue_construction_move(worker: State.Worker, phase: StringName,
		finish: Vector2, speed: float) -> bool:
	if phase in [&"join_platform", &"climb_to_platform"] \
			and worker.position.is_equal_approx(finish):
		_waiting.erase(worker.id)
		_waiting_attempt.erase(worker.id)
		_waiting_reason.erase(worker.id)
		return true
	var route := _construction_route(worker.position, finish)
	if phase == &"walk_to_workshop" and _state.geometry.has_custom_blueprint() \
			and worker.position.y > 0.0:
		var entry := _first_scaffold_entry()
		var to_entry := _construction_route(worker.position, entry)
		var from_entry := _construction_route(entry, finish)
		if not to_entry.is_empty() and not from_entry.is_empty():
			to_entry.append_array(from_entry.slice(1))
			route = to_entry
		else:
			route = PackedVector2Array()
			_route_failure = "scaffold_entry_unreachable"
	if route.is_empty() and phase == &"climb_to_platform" and _state.current_row > 0:
		var climb := _state.geometry.platform_to_next_row(_state.current_row - 1)
		if not climb.is_empty() and worker.position.is_equal_approx(climb[0]) \
				and finish.is_equal_approx(climb[-1]):
			route = climb
	if route.is_empty() and phase in [&"walk_to_workshop", &"walk_to_lift"] \
			and _state.current_row > 0 and not _state.geometry.has_custom_blueprint():
		var descent := _state.geometry.platform_to_lift_operator(_state.current_row)
		if not descent.is_empty() and worker.position.is_equal_approx(descent[0]) \
				and (finish.is_equal_approx(_state.geometry.workshop_pickup()) \
				or finish.is_equal_approx(_state.geometry.lift_operator_position())):
			if phase == &"walk_to_workshop":
				descent.append(finish)
			route = descent
	if route.is_empty() and phase == &"return_from_lift" and _state.current_row > 0 \
			and not _state.geometry.has_custom_blueprint():
		var ascent := _state.geometry.platform_to_lift_operator(_state.current_row)
		ascent.reverse()
		if not ascent.is_empty() and worker.position.is_equal_approx(ascent[0]) \
				and finish.is_equal_approx(ascent[-1]):
			route = ascent
	if route.is_empty() and not _state.geometry.has_custom_blueprint() \
			and phase in [&"walk_to_brick", &"return_to_platform"]:
		var column := _state.placed_count() - _state.row_start
		if phase == &"return_to_platform":
			column -= 1
		var masonry := _state.geometry.builder_to_brick(_state.current_row, column)
		if phase == &"return_to_platform":
			masonry.reverse()
		if not masonry.is_empty() and worker.position.is_equal_approx(masonry[0]):
			route = masonry
	if route.is_empty() or not worker.queue_move(phase, route, speed):
		_waiting[worker.id] = phase
		_waiting_attempt[worker.id] = _route_stamp()
		_waiting_reason[worker.id] = _route_failure if route.is_empty() else "invalid_route"
		return false
	_waiting.erase(worker.id)
	_waiting_attempt.erase(worker.id)
	_waiting_reason.erase(worker.id)
	return true


func _first_scaffold_entry() -> Vector2:
	var unit := _state.geometry.brick_size()
	var left := INF
	for block: Dictionary in _placed_snapshot.blocks:
		left = minf(left, float(block.x0))
	return Vector2(left - 2.0 * unit.x, 0.0) if is_finite(left) \
		else _state.geometry.platform(0)


func _queue_return() -> void:
	var builder := _state.worker(_state.active_builder_id)
	var destination := _landing()
	if _state.geometry.has_custom_blueprint() and _state.completed_rows > _state.current_row:
		destination = _first_scaffold_entry()
	_queue_construction_move(builder, &"return_to_platform", destination, _builder_speed)


func _retry_builder_route(builder: State.Worker) -> void:
	if builder.fsm_state != &"idle":
		return
	if _waiting.get(builder.id) in [&"join_platform", &"climb_to_platform"] \
			and builder.position.is_equal_approx(_landing()):
		_waiting.erase(builder.id)
		_waiting_attempt.erase(builder.id)
		_waiting_reason.erase(builder.id)
		return
	if _waiting_attempt.get(builder.id, -1) == _route_stamp():
		return
	match _waiting.get(builder.id):
		&"walk_to_brick":
			_queue_placement()
		&"return_to_platform":
			_queue_return()
		&"walk_to_workshop":
			_queue_construction_move(builder, &"walk_to_workshop",
				_state.geometry.workshop_pickup(), _builder_speed)
		&"walk_to_lift_base":
			_queue_construction_move(builder, &"walk_to_lift_base",
				_state.geometry.finished_storage(),
				_builder_speed / _state.geometry.block_multiplier(_state.placed_count()))
		&"walk_to_lift":
			_queue_construction_move(builder, &"walk_to_lift",
				_state.geometry.lift_operator_position(), _builder_speed)
		&"return_from_lift", &"join_platform", &"climb_to_platform":
			var phase: StringName = _waiting[builder.id]
			_queue_construction_move(builder, phase,
				_landing(), _builder_speed)


func _retry_waiting_helpers() -> void:
	for id in _waiting.keys():
		if id == _state.active_builder_id or _waiting[id] != &"return_from_lift":
			continue
		if _waiting_attempt.get(id, -1) == _route_stamp():
			continue
		var worker := _state.worker(id)
		if worker.fsm_state != &"idle":
			continue
		var destination := _state.geometry.workshop() if worker.role == State.Worker.Role.DRESSER \
			else _state.geometry.raw_storage()
		_queue_construction_move(worker, &"return_from_lift", destination, _helper_speed(worker))


func _active_route_valid(worker: State.Worker, route: PackedVector2Array) -> bool:
	var points := PackedVector2Array()
	if worker.path_segment + 1 >= route.size():
		return worker.position.is_equal_approx(route[-1])
	if worker.path_segment + 1 < route.size():
		var from := route[worker.path_segment]
		var to := route[worker.path_segment + 1]
		if absf(from.distance_to(worker.position) + worker.position.distance_to(to)
				- from.distance_to(to)) > 0.0001:
			return false
		points.append(from)
	for index in range(worker.path_segment + 1, route.size()):
		points.append(route[index])
	for index in range(1, points.size()):
		if worker.fsm_state not in [&"walk_to_brick", &"return_to_platform",
				&"climb_to_platform", &"join_platform"]:
			var unit := _state.geometry.brick_size()
			if not _state.geometry._scaffold_clear_segment(_placed_snapshot,
					points[index - 1], points[index], 0.18 * unit.x,
					0.9 * unit.y, 0.02 * unit.y):
				return false
			continue
		var settings := {"include_surfaces": false} if _state.geometry.has_custom_blueprint() else {}
		if not Routes.has_segment(_state.geometry, _placed_snapshot, _scaffolds,
				points[index - 1], points[index], settings):
			return false
	return true


func _replan_active_moves(keep_valid := false) -> void:
	_refresh_routes()
	for id in _state.worker_ids():
		var worker := _state.worker(id)
		if worker.role == State.Worker.Role.MINER or worker.role == State.Worker.Role.LIFT:
			continue
		var old_route := worker.movement_route()
		if old_route.is_empty() or worker.fsm_state not in [
				&"walk_to_brick", &"return_to_platform", &"climb_to_platform",
				&"join_platform", &"walk_to_workshop", &"walk_to_lift_base",
				&"walk_to_lift", &"return_from_lift"]:
			continue
		if keep_valid and _active_route_valid(worker, old_route):
			worker.route_waiting = false
			_waiting.erase(id)
			continue
		var route := _construction_route(worker.position, old_route[-1])
		if route.is_empty():
			worker.route_waiting = true
			_waiting[id] = worker.fsm_state
			_waiting_attempt[id] = _route_stamp()
			_waiting_reason[id] = _route_failure
		else:
			worker.replan_active_move(route)
			_waiting.erase(id)
			_waiting_attempt.erase(id)
			_waiting_reason.erase(id)


func _retry_paused_moves() -> void:
	for id in _state.worker_ids():
		var worker := _state.worker(id)
		if not worker.route_waiting:
			continue
		if _waiting_attempt.get(id, -1) == _route_stamp():
			continue
		var old_route := worker.movement_route()
		if old_route.is_empty():
			continue
		var route := _construction_route(worker.position, old_route[-1])
		if not route.is_empty() and worker.replan_active_move(route):
			_waiting.erase(id)
			_waiting_attempt.erase(id)
			_waiting_reason.erase(id)
		else:
			_waiting_attempt[id] = _route_stamp()
			_waiting_reason[id] = _route_failure
