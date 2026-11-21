extends RefCounted

const State = preload("res://scripts/domain/game_state.gd")
const ScaffoldRoad = preload("res://scripts/domain/scaffold_road.gd")
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
var _road := ScaffoldRoad.new()


func _init(state: State, balance: Dictionary) -> void:
	_state = state
	_process_seconds = float(balance.workers.dresser.processSeconds)
	_place_seconds = float(balance.workers.builder.placeSeconds)
	_unload_seconds = float(balance.workers.porter.unloadSeconds)
	_builder_speed = float(balance.workers.builder.moveSpeed)
	_miner_speed = float(balance.workers.miner.moveSpeed)
	_porter_speed = float(balance.workers.porter.emptySpeed)
	_dresser_speed = float(balance.workers.dresser.get("moveSpeed", _builder_speed))
	_refresh_routes()


func apply_completion(event: Dictionary) -> void:
	match event.state:
		&"walk_to_quarry_stock":
			# Only a previously saved dresser walk can still have this phase.
			var dresser := _state.worker(event.worker_id)
			var targets := _state.pickup_targets(dresser.id)
			if not targets.is_empty() and _state.pick_up(dresser.id, targets[0]):
				var geometry := _state.geometry
				dresser.queue_move(&"return_to_workshop",
					[dresser.position, geometry.workshop()], _dresser_speed)
			else:
				_state.cancel_transfer(dresser.id)
		&"return_to_workshop":
			_state.worker(event.worker_id).queue_work(&"process_brick", _process_seconds, 1.0)
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
				var row_complete := _state.placed_count() == _state.row_start + _state.geometry.row_size(_state.current_row)
				if row_complete:
					_state.completed_rows += 1
				_state.finished = _state.placed_count() == _state.target_count()
				_refresh_routes()
				var builder := _state.worker(_state.active_builder_id)
				if not _state.finished and builder.fsm_state == &"idle":
					_queue_return()
		&"return_to_platform":
			if _state.completed_rows == _state.current_row:
				_rotate_builder()
		&"rebuild_platform":
			_state.current_row += 1
			_state.row_start = _state.placed_count()
			_refresh_routes()
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
		var landing: Vector2 = _landing()
		_state.active_builder_id = id
		if not next.position.is_equal_approx(landing):
			_queue_construction_move(next, &"join_platform", landing, _builder_speed)
		return


func assign_tasks() -> void:
	var dressers := _state.worker_ids_for_role(State.Worker.Role.DRESSER)
	var start := _state.next_dresser_index
	for offset in range(dressers.size()):
		var index := (start + offset) % dressers.size()
		var id := dressers[index]
		var dresser := _state.worker(id)
		var next_input := _next_raw_resource()
		if dresser.fsm_state == &"idle" and next_input >= 0 and _assign_dresser(dresser, next_input):
			_state.next_dresser_index = (index + 1) % dressers.size()

	var builder := _state.worker(_state.active_builder_id)
	var geometry := _state.geometry
	var row := _state.current_row
	_refresh_routes()
	if _state.completed_rows > row:
		if builder.fsm_state == &"idle" and _state.worker(Owner.LIFT).fsm_state == &"idle":
			builder.queue_work(&"rebuild_platform", geometry.rebuild_seconds(), 1.0)
		return
	if _needs_lift() and _miner_at_lift() and _state.lift_operator_id() == -1:
		_start_manual_lift(Owner.MINER)
	if builder.fsm_state != &"idle" or _resume_builder_transfer(builder):
		return

	var source := Owner.FINISHED if row == 0 and _state.stock_count(Owner.PLATFORM) == 0 else Owner.PLATFORM
	if source == Owner.PLATFORM and _state.stock_count(source) > 0 \
			and not builder.position.is_equal_approx(_landing()):
		_queue_construction_move(builder, &"join_platform", _landing(), _builder_speed)
		return
	if _take_input(builder.id, source):
		_queue_placement()
	elif _state.worker(Owner.LIFT).fsm_state != &"idle" or _state.lift_operator_id() != -1:
		return
	elif _needs_lift():
		return # Choose an operator after the quarry has assigned its jobs.
	elif row == 0 or _state.free_slots(Owner.FINISHED) > 0:
		var output := _state.stock(Owner.WORKSHOP_OUTPUT)
		var brick: int = _state.placed_count() if geometry.has_custom_blueprint() else output.front() if not output.is_empty() else -1
		if brick in output and _state.reserve_transfer(builder.id, [brick], Owner.WORKSHOP_OUTPUT):
			_queue_construction_move(builder, &"walk_to_workshop", geometry.workshop_pickup(), _builder_speed)


func assign_assistance() -> void:
	var builder := _state.worker(_state.active_builder_id)
	if not _needs_lift() or _miner_at_lift() or _state.lift_operator_id() != -1 \
			or builder.fsm_state not in [&"idle", &"climb_to_platform", &"return_to_platform"]:
		return
	var geometry := _state.geometry
	if _send_exhausted_miner():
		return

	# Choose the idle worker who can reach the crank before the builder returns to ground.
	var best: State.Worker
	var best_route := PackedVector2Array()
	var descent := _road.route(_landing(), geometry.lift_operator_position())
	var builder_distance := builder.position.distance_to(_landing()) + geometry.route_length(descent)
	var best_time := builder_distance / (_builder_speed * builder.speed_multiplier)
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
	elif builder.fsm_state == &"idle":
		_queue_construction_move(builder, &"walk_to_lift", geometry.lift_operator_position(), _builder_speed)


func _helper_lift_route(worker: State.Worker) -> PackedVector2Array:
	var geometry := _state.geometry
	if worker.id == Owner.MINER:
		return geometry.miner_to_lift_operator(_state.mined_count(), worker.position)
	return _road.route(worker.position, geometry.lift_operator_position())


func _helper_speed(worker: State.Worker) -> float:
	match worker.id:
		Owner.MINER: return _miner_speed
		Owner.DRESSER: return _dresser_speed
	return _porter_speed


func _miner_at_lift() -> bool:
	var miner := _state.worker(Owner.MINER)
	return miner.position == _state.geometry.lift_operator_position() \
		and miner.fsm_state in [&"idle", &"exhausted", &"operate_lift"] \
		and _state.mined_count() >= _state.target_count()


func _send_exhausted_miner() -> bool:
	var miner := _state.worker(Owner.MINER)
	return miner.fsm_state == &"exhausted" and _state.placed_count() + 1 < _state.target_count() \
		and miner.queue_move(&"walk_to_lift", _helper_lift_route(miner), _miner_speed)


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
	if _miner_at_lift() or (_state.lift_operator_id() == -1 and _needs_lift() and _send_exhausted_miner()):
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
	if _needs_lift() and _take_input(Owner.LIFT, Owner.FINISHED):
		_state.delivery_point = _road.tip()
		var resource: int = _state.stock(Owner.LIFT)[0]
		var route := geometry.lift_route(row, _landing(), geometry.block_size_for_resource(resource))
		var duration := geometry.lift_seconds(row) * geometry.block_multiplier(resource)
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


func _assign_dresser(dresser: State.Worker, resource_id: int) -> bool:
	if not _take_input(dresser.id, Owner.RAW, resource_id):
		return false
	return dresser.queue_work(&"process_brick", _process_seconds, 1.0)


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
		for resource_id: int in raw:
			if _state.reserved_by(resource_id) == -1:
				return resource_id
		return -1
	for resource_id in range(_state.placed_count(), _state.target_count()):
		var owner := _state.owner_of(resource_id)
		if owner == Owner.RAW:
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
	var placed := _state.placed_count()
	var row := _state.current_row
	if _route_revision == placed and _route_row == row:
		return
	_route_revision = placed
	_route_row = row
	_road.extend(_state.geometry, row, _state.row_start, placed)
	_state.scaffold_paths = _road.paths
	if row > 0:
		var lift := _state.worker(Owner.LIFT)
		var lift_route := lift.movement_route()
		if not lift_route.is_empty():
			_state.delivery_point = lift_route[-1]
		elif _state.stock_count(Owner.PLATFORM) == 0 or not _state.delivery_point.is_finite():
			_state.delivery_point = _road.tip()


func _landing() -> Vector2:
	return _state.platform_position()


func _placement_point() -> Vector2:
	_refresh_routes()
	return _road.tip()


func _queue_construction_move(worker: State.Worker, phase: StringName,
		finish: Vector2, speed: float) -> bool:
	return worker.queue_move(phase, _road.route(worker.position, finish), speed)


func _queue_return() -> void:
	var builder := _state.worker(_state.active_builder_id)
	var destination := _road.row_entry() if _state.completed_rows > _state.current_row else _road.tip()
	_queue_construction_move(builder, &"return_to_platform", destination, _builder_speed)


func _needs_lift() -> bool:
	if _state.current_row == 0 or _state.completed_rows > _state.current_row \
			or _state.stock_count(Owner.PLATFORM) > 0 or _state.worker(Owner.LIFT).fsm_state != &"idle" \
			or _state.stock_count(_state.active_builder_id) > 0:
		return false
	var stock := _state.stock(Owner.FINISHED)
	return _state.placed_count() in stock if _state.geometry.has_custom_blueprint() else not stock.is_empty()


# A snapshot keeps its active route, including the destination of an in-flight lift.
func restore_routes(saved_waiting: Variant) -> bool:
	if not saved_waiting is Dictionary:
		return false
	_refresh_routes()
	for id in _state.worker_ids():
		_state.worker(id).route_waiting = false
	return true


func _resume_builder_transfer(builder: State.Worker) -> bool:
	if _state.task_resource_ids(builder.id).is_empty():
		return false
	if _state.stock_count(builder.id) == 0:
		_queue_construction_move(builder, &"walk_to_workshop",
			_state.geometry.workshop_pickup(), _builder_speed)
	elif _state.current_row > 0 and _state.transfer_source(builder.id) == Owner.WORKSHOP_OUTPUT:
		_queue_construction_move(builder, &"walk_to_lift_base", _state.geometry.finished_storage(),
			_builder_speed / _state.geometry.block_multiplier(_state.placed_count()))
	else:
		_queue_placement()
	return true
