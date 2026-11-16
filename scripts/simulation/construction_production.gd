extends RefCounted

const State = preload("res://scripts/domain/game_state.gd")
const Owner = State.Owner

var _state: State
var _process_seconds: float
var _place_seconds: float
var _unload_seconds: float
var _builder_speed: float
var _miner_speed: float
var _porter_speed: float


func _init(state: State, balance: Dictionary) -> void:
	_state = state
	_process_seconds = float(balance.workers.dresser.processSeconds)
	_place_seconds = float(balance.workers.builder.placeSeconds)
	_unload_seconds = float(balance.workers.porter.unloadSeconds)
	_builder_speed = float(balance.workers.builder.moveSpeed)
	_miner_speed = float(balance.workers.miner.moveSpeed)
	_porter_speed = float(balance.workers.porter.emptySpeed)


func migrate_pyramid_routes() -> bool:
	var geometry := _state.geometry
	var row := _state.current_row
	if row == 0 or not geometry.has_pyramid_ramp():
		return true
	return _state.worker(Owner.BUILDER).remap_saved_routes(
		func(phase: StringName, route: PackedVector2Array) -> PackedVector2Array:
			var landing: Vector2 = geometry.platform(row)
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
			_deliver(Owner.DRESSER)
		&"lift_brick":
			if _deliver(Owner.LIFT):
				_state.worker(Owner.LIFT).position = _state.geometry.finished_storage()
		&"walk_to_lift":
			_start_manual_lift(event.worker_id)
		&"walk_to_workshop":
			_pick_up_at_workshop()
		&"walk_to_lift_base":
			var builder := _state.worker(Owner.BUILDER)
			if builder.fsm_state == &"walk_to_lift":
				# Older saves already have the walk to the crank queued.
				_deliver(Owner.BUILDER)
			else:
				builder.queue_work(&"unload_at_lift", _unload_seconds, 1.0)
		&"unload_at_lift":
			if _deliver(Owner.BUILDER):
				_after_builder_unload()
		&"place_brick":
			var placement_index := _state.placed_count()
			if _deliver(Owner.BUILDER):
				event["placement_index"] = placement_index
				var row_complete := _state.placed_count() == _state.row_start + _state.geometry.row_size(_state.current_row)
				if row_complete:
					_state.completed_rows += 1
				_state.finished = _state.placed_count() == State.RESOURCE_COUNT
				var builder := _state.worker(Owner.BUILDER)
				if not _state.finished and builder.fsm_state == &"idle":
					var column := placement_index - _state.row_start
					var route := _state.geometry.builder_to_brick(_state.current_row, column)
					route.reverse()
					builder.queue_move(&"return_to_platform", route, _builder_speed)
		&"rebuild_platform":
			var route := _state.geometry.platform_to_next_row(_state.current_row)
			_state.current_row += 1
			_state.row_start = _state.placed_count()
			_state.worker(Owner.BUILDER).queue_move(&"climb_to_platform", route, _builder_speed)


func assign_tasks() -> void:
	var dresser := _state.worker(Owner.DRESSER)
	if dresser.fsm_state == &"idle" and _take_input(Owner.DRESSER, Owner.RAW):
		dresser.queue_work(&"process_brick", _process_seconds, 1.0)

	var lift := _state.worker(Owner.LIFT)
	var builder := _state.worker(Owner.BUILDER)
	var geometry := _state.geometry
	var row := _state.current_row
	if _state.completed_rows > row:
		if builder.fsm_state == &"idle" and lift.fsm_state == &"idle":
			builder.queue_work(&"rebuild_platform", geometry.rebuild_seconds(), 1.0)
		return
	if row > 0 and lift.fsm_state == &"idle" and _miner_at_lift() and _state.lift_operator_id() == -1:
		_start_manual_lift(Owner.MINER)
	if builder.fsm_state != &"idle":
		return

	# Clear bricks already at the platform or lift base, including those in old saves.
	var source := Owner.FINISHED if row == 0 and _state.stock_count(Owner.PLATFORM) == 0 else Owner.PLATFORM
	if _take_input(Owner.BUILDER, source):
		_queue_placement()
	elif lift.fsm_state != &"idle" or _state.lift_operator_id() != -1:
		return
	elif row > 0 and _state.stock_count(Owner.FINISHED) > 0 and _state.free_slots(Owner.PLATFORM) > 0:
		builder.queue_move(&"walk_to_lift", geometry.platform_to_lift_operator(row), _builder_speed)
	else:
		if row > 0 and _state.free_slots(Owner.FINISHED) == 0:
			return
		for brick: int in _state.stock(Owner.WORKSHOP_OUTPUT):
			if not _state.reserve_transfer(Owner.BUILDER, [brick], Owner.WORKSHOP_OUTPUT):
				continue
			var route := geometry.platform_to_lift_operator(row) if row > 0 else PackedVector2Array([builder.position])
			route.append(geometry.workshop_pickup())
			if not builder.queue_move(&"walk_to_workshop", route, _builder_speed):
				_state.cancel_transfer(Owner.BUILDER)
			break


func assign_assistance() -> void:
	var row := _state.current_row
	var builder := _state.worker(Owner.BUILDER)
	if row == 0 or _state.completed_rows > row \
			or builder.fsm_state not in [&"walk_to_brick", &"place_brick", &"return_to_platform"]:
		return
	if _miner_at_lift() or _state.stock_count(Owner.FINISHED) == 0 or _state.free_slots(Owner.PLATFORM) <= 0 \
			or _state.worker(Owner.LIFT).fsm_state != &"idle" or _state.lift_operator_id() != -1:
		return
	var geometry := _state.geometry
	var remaining := geometry.row_size(row) - (_state.placed_count() - _state.row_start) - _state.stock_count(Owner.BUILDER)
	if _state.stock_count(Owner.PLATFORM) >= remaining:
		return

	# Choose the idle worker who can reach the crank first.
	var best: State.Worker
	var best_route := PackedVector2Array()
	var best_time := INF
	if _state.stock_count(Owner.PLATFORM) == 0:
		# Avoid sending help that would reach the crank after the builder.
		var builder_distance := builder.position.distance_to(geometry.platform(row)) \
			+ geometry.route_length(geometry.platform_to_lift_operator(row))
		best_time = builder_distance / (_builder_speed * builder.speed_multiplier)
		match builder.fsm_state:
			&"walk_to_brick":
				best_time += _place_seconds / builder.speed_multiplier
			&"place_brick":
				best_time += builder.remaining_work / builder.speed_multiplier
	for id in _state.worker_ids():
		if id in [Owner.BUILDER, Owner.LIFT]:
			continue
		var worker := _state.worker(id)
		var available := &"exhausted" if id == Owner.MINER else &"idle"
		if worker.fsm_state != available:
			continue
		var speed := _helper_speed(worker) * worker.speed_multiplier
		if not is_finite(speed) or speed <= 0.0:
			continue
		var route := _helper_lift_route(worker)
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
	var start := geometry.workshop() if worker.id == Owner.DRESSER else geometry.raw_storage()
	return PackedVector2Array([start, geometry.lift_operator_position()])


func _helper_speed(worker: State.Worker) -> float:
	match worker.id:
		Owner.MINER: return _miner_speed
		Owner.DRESSER: return _builder_speed
	return _porter_speed


func _miner_at_lift() -> bool:
	var miner := _state.worker(Owner.MINER)
	return miner.position == _state.geometry.lift_operator_position() \
		and miner.fsm_state in [&"idle", &"exhausted", &"operate_lift"] \
		and _state.mined_count() == State.RESOURCE_COUNT


func _pick_up_at_workshop() -> void:
	var pending := _state.task_resource_ids(Owner.BUILDER)
	if pending.is_empty() or not _state.pick_up(Owner.BUILDER, pending[0]):
		return
	var geometry := _state.geometry
	if _state.current_row == 0:
		_queue_placement()
		return
	var builder := _state.worker(Owner.BUILDER)
	var base := geometry.finished_storage()
	builder.queue_move(&"walk_to_lift_base", PackedVector2Array([geometry.workshop_pickup(), base]), _builder_speed)


func _after_builder_unload() -> void:
	var builder := _state.worker(Owner.BUILDER)
	var geometry := _state.geometry
	var route := geometry.platform_to_lift_operator(_state.current_row)
	if _miner_at_lift():
		route.resize(route.size() - 1)
		route.reverse()
		builder.queue_move(&"return_from_lift", route, _builder_speed)
	else:
		builder.queue_move(&"walk_to_lift", [geometry.finished_storage(), route[-1]], _builder_speed)


func _queue_placement() -> void:
	var builder := _state.worker(Owner.BUILDER)
	var column := _state.placed_count() - _state.row_start
	var route := _state.geometry.builder_to_brick(_state.current_row, column)
	if route.is_empty():
		return
	if route[0] != builder.position:
		route.insert(0, builder.position)
	if builder.queue_move(&"walk_to_brick", route, _builder_speed):
		builder.queue_work(&"place_brick", _place_seconds, 1.0)


func _start_manual_lift(operator_id: int) -> void:
	var geometry := _state.geometry
	var row := _state.current_row
	var operator := _state.worker(operator_id)
	var lift := _state.worker(Owner.LIFT)
	var builder := _state.worker(Owner.BUILDER)
	if _state.completed_rows == row and builder.fsm_state not in [&"rebuild_platform", &"climb_to_platform"] \
			and lift.fsm_state == &"idle" and _take_input(Owner.LIFT, Owner.FINISHED):
		var route := geometry.lift_route(row)
		var duration := geometry.lift_seconds(row)
		lift.position = route[0]
		lift.queue_move(&"lift_brick", route, geometry.route_length(route) / duration)
		operator.queue_work(&"operate_lift", duration, 1.0)
	if operator_id == Owner.MINER:
		return
	var is_builder := operator_id == Owner.BUILDER
	var walk := geometry.platform_to_lift_operator(row) if is_builder else _helper_lift_route(operator)
	walk.reverse()
	operator.queue_move(&"return_from_lift", walk, _builder_speed if is_builder else _helper_speed(operator))


func _take_input(worker_id: int, source: int) -> bool:
	var stock := _state.stock(source)
	if stock.is_empty():
		return false
	var resource_id: int = stock[0]
	if not _state.reserve_transfer(worker_id, [resource_id], source):
		return false
	if _state.pick_up(worker_id, resource_id):
		return true
	_state.cancel_transfer(worker_id)
	return false


func _deliver(worker_id: int) -> bool:
	var pending := _state.task_resource_ids(worker_id)
	return not pending.is_empty() and _state.deliver(worker_id, pending[0])
