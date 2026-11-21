extends RefCounted

const State = preload("res://scripts/domain/game_state.gd")
const Owner = State.Owner

var _state: State
var _miner_config: Dictionary
var _porter_config: Dictionary


func _init(state: State, workers: Dictionary) -> void:
	_state = state
	_miner_config = workers.miner.duplicate()
	_porter_config = workers.porter.duplicate()


func apply_completion(event: Dictionary) -> void:
	var worker_id: int = event.worker_id
	var worker := _state.worker(worker_id)
	if worker == null or worker.role not in [State.Worker.Role.MINER, State.Worker.Role.PORTER]:
		return
	match event.state:
		&"mine":
			var pending := _state.task_resource_ids(worker_id)
			if not pending.is_empty() and _state.deliver(worker_id, pending[0]):
				event["resource_id"] = pending[0]
				if _state.geometry.quarry_slopes != null and _state.geometry.quarry_excavation == null:
					_follow_quarry_surface(worker_id)
		&"unload":
			var cargo := _state.stock(worker_id)
			if not cargo.is_empty():
				_state.deliver(worker_id, cargo[-1])
		&"load":
			var targets := _state.pickup_targets(worker_id)
			if not targets.is_empty():
				_state.pick_up(worker_id, targets[0])


func _follow_quarry_surface(worker_id: int) -> void:
	var slopes := _state.geometry.quarry_slopes
	var mined := _state.mined_count()
	var miner := _state.worker(worker_id)
	miner.position = _state.geometry.miner_work_position(mined - 1, mined)
	var follow := func(start: Vector2, finish: Vector2) -> PackedVector2Array:
		return _quarry_surface_route(start, finish, mined)
	for id in _state.worker_ids():
		var worker := _state.worker(id)
		if _state.transfer_source(id) == Owner.QUARRY or worker.fsm_state == &"return_to_quarry":
			worker.follow_quarry_surface(follow, slopes.project(worker.position, mined))
		elif worker.role == State.Worker.Role.MINER and id != worker_id and worker.fsm_state == &"idle":
			worker.position = slopes.project(worker.position, mined)


func _quarry_surface_route(start: Vector2, finish: Vector2, mined: int) -> PackedVector2Array:
	var slopes := _state.geometry.quarry_slopes
	var raw := _state.geometry.raw_storage()
	if _state.geometry.quarry_excavation != null:
		if start.y < raw.y and finish.y == raw.y and finish.x > raw.x:
			return slopes.route(start, raw, mined) + PackedVector2Array([finish])
		if finish.y < raw.y and start.y == raw.y and start.x > raw.x:
			return PackedVector2Array([start]) + slopes.route(raw, finish, mined)
		return slopes.route(start, finish, mined)
	var leftward := start.x > finish.x
	var left := slopes.project(finish if leftward else start, mined)
	var right := slopes.project(start if leftward else finish, mined)
	var route := slopes.route(left, raw if left.x < raw.x and right.x > raw.x else right, mined)
	if route[-1] != right:
		route.append(right)
	if leftward:
		route.reverse()
	return route


func assign_tasks() -> void:
	# Let a blocked miner claim a slot before the porter reserves the whole batch.
	var miners := _state.worker_ids_for_role(State.Worker.Role.MINER)
	for offset in range(miners.size()):
		var index := (_state.mined_count() + offset) % miners.size()
		var miner := _state.worker(miners[index])
		if miner.fsm_state == &"idle":
			_assign_miner(miner.id)
			break
	for worker_id in _state.worker_ids_for_role(State.Worker.Role.PORTER):
		_assign_porter(worker_id)


func _assign_miner(worker_id: int) -> bool:
	var miner := _state.worker(worker_id)
	if miner.fsm_state != &"idle":
		return false
	var resource_id := _state.mined_count()
	if resource_id >= _state.target_count():
		miner.fsm_state = &"exhausted"
		return false
	if not _state.reserve_transfer(worker_id, [resource_id]):
		if _state.free_slots(Owner.QUARRY) == 0:
			_clear_quarry_slot(miner, resource_id - 1)
		return false

	var route := _state.geometry.miner_to_next_cell(resource_id - 1)
	if not route.is_empty() and not route[0].is_equal_approx(miner.position):
		if _state.geometry.quarry_slopes != null:
			route = _state.geometry.quarry_slopes.route(miner.position, route[-1], resource_id)
		else:
			route.insert(0, miner.position)
	if not miner.queue_move(&"move_to_cell", route, float(_miner_config.moveSpeed)):
		_state.cancel_transfer(worker_id)
		return false
	miner.queue_work(&"mine", float(_miner_config.mineSeconds) * _state.geometry.block_multiplier(resource_id), 1.0)
	return true


func _clear_quarry_slot(miner: State.Worker, previous_id: int) -> void:
	if previous_id < 0 or _state.free_slots(Owner.RAW) == 0:
		return
	var geometry := _state.geometry
	var target := -1
	var best := INF
	for id: int in _state.stock(Owner.QUARRY):
		if _state.reserved_by(id) != -1 or not _eligible_raw_resource(id):
			continue
		var length := float(id) if geometry.has_custom_blueprint() else (
			geometry.route_length(geometry.miner_to_pickup(previous_id, id))
			+ geometry.route_length(geometry.quarry_to_raw(id, previous_id + 1)))
		if length < best:
			best = length
			target = id
	if target == -1 or not _state.reserve_transfer(miner.id, [target], Owner.QUARRY):
		return
	var speed := float(_miner_config.moveSpeed) / geometry.block_multiplier(target)
	var pickup_route := geometry.miner_to_pickup(previous_id, target)
	if not pickup_route.is_empty() and not pickup_route[0].is_equal_approx(miner.position):
		if geometry.quarry_slopes != null:
			pickup_route = geometry.quarry_slopes.route(miner.position, pickup_route[-1], previous_id + 1)
		else:
			pickup_route.insert(0, miner.position)
	if not miner.queue_move(&"walk_to_pickup", pickup_route, speed):
		_state.cancel_transfer(miner.id)
		return
	miner.queue_work(&"load", float(_porter_config.loadSeconds), 1.0)
	var slot := _state.raw_place(target)
	var approach := geometry.quarry_to_raw(target, previous_id + 1)
	if approach[-1] != slot:
		approach.append(slot)
	miner.queue_move(&"walk_to_storage", approach, speed)
	miner.queue_work(&"unload", float(_porter_config.unloadSeconds), 1.0)
	miner.queue_move(&"return_to_quarry", geometry.raw_to_miner(previous_id, slot), speed)


func _assign_porter(worker_id: int) -> void:
	var porter := _state.worker(worker_id)
	if porter.fsm_state != &"idle":
		return
	var empty_speed := float(_porter_config.emptySpeed)
	var loaded_speed := float(_porter_config.loadedSpeed)
	var load_seconds := float(_porter_config.loadSeconds)
	var unload_seconds := float(_porter_config.unloadSeconds)
	if not is_finite(empty_speed) or empty_speed <= 0.0 or not is_finite(loaded_speed) or loaded_speed <= 0.0:
		return
	if not is_finite(load_seconds) or load_seconds < 0.0 or not is_finite(unload_seconds) or unload_seconds < 0.0:
		return

	var geometry := _state.geometry
	var limit := mini(_state.porter_capacity, _state.free_slots(Owner.RAW))
	if limit <= 0:
		return

	# Reserve all pickup targets and their unloading slots together.
	var mined := _state.mined_count()
	var distances: Dictionary[int, float] = {}
	for resource_id: int in _state.stock(Owner.QUARRY):
		if _state.reserved_by(resource_id) == -1 and _eligible_raw_resource(resource_id):
			distances[resource_id] = geometry.route_length(geometry.quarry_to_raw(resource_id, mined))
	var candidates := distances.keys()
	if candidates.is_empty():
		return
	candidates.sort_custom(func(a: int, b: int) -> bool:
		if geometry.has_custom_blueprint():
			return a < b
		return a < b if distances[a] == distances[b] else distances[a] < distances[b]
	)
	var batch: Array[int] = []
	for index in range(mini(limit, candidates.size())):
		batch.append(candidates[index])

	# Travel the full approach empty when that is faster, then collect on the way out.
	if empty_speed >= loaded_speed and not geometry.has_custom_blueprint():
		batch.reverse()
	batch = _reserve_raw_batch(worker_id, batch)
	if batch.is_empty():
		return
	var pickup_route := geometry.quarry_to_raw(batch[0], mined)
	pickup_route.reverse()
	if pickup_route[0] != porter.position:
		pickup_route.insert(0, porter.position)
	if not porter.queue_move(&"walk_to_pickup", pickup_route, empty_speed):
		_state.cancel_transfer(worker_id)
		return
	porter.queue_work(&"load", load_seconds, 1.0)
	for index in range(1, batch.size()):
		var route := geometry.quarry_between_pickups(batch[index - 1], batch[index], mined)
		porter.queue_move(&"walk_to_pickup", route, _loaded_speed(batch.slice(0, index)))
		porter.queue_work(&"load", load_seconds, 1.0)
	_queue_raw_unload(porter, batch, geometry.quarry_to_raw(batch[-1], mined))


func _eligible_raw_resource(resource_id: int) -> bool:
	return not _state.geometry.has_custom_blueprint() or resource_id < _state.target_count()


func _reserve_raw_batch(worker_id: int, candidates: Array[int]) -> Array[int]:
	for count in range(candidates.size(), 0, -1):
		var batch := candidates.slice(0, count)
		if _state.reserve_transfer(worker_id, batch):
			return batch
	return []


func _queue_raw_unload(porter: State.Worker, batch: Array[int], approach: PackedVector2Array) -> void:
	# The top of the sled is always the block loaded last.
	approach.append(_state.raw_place(batch[-1]))
	porter.queue_move(&"walk_to_storage", approach, _loaded_speed(batch))
	for index in range(batch.size() - 1, -1, -1):
		if index < batch.size() - 1:
			var route := PackedVector2Array([_state.raw_place(batch[index + 1]), _state.raw_place(batch[index])])
			porter.queue_move(&"walk_to_storage", route, _loaded_speed(batch.slice(0, index + 1)))
		porter.queue_work(&"unload", float(_porter_config.unloadSeconds), 1.0)
	porter.queue_move(&"return_to_raw_storage",
		[_state.raw_place(batch[0]), _state.geometry.raw_storage()], float(_porter_config.emptySpeed))


func _loaded_speed(resources: Array[int]) -> float:
	var multiplier := clampf(float(_porter_config.get("extraItemSpeedMultiplier", 0.94)), 0.9, 1.0)
	var block_multiplier := 1.0
	for resource_id in resources:
		block_multiplier = maxf(block_multiplier, _state.geometry.block_multiplier(resource_id))
	return float(_porter_config.loadedSpeed) * pow(multiplier, resources.size() - 1) / block_multiplier


func migrate_saved_routes() -> bool:
	if _state.geometry.quarry_excavation != null:
		return _migrate_block_cut_routes()
	if not _migrate_miner():
		return false
	for worker_id in _state.worker_ids():
		if worker_id >= Owner.FIRST_PORTER and _state.transfer_source(worker_id) == Owner.QUARRY \
				and not _migrate_haul(worker_id):
			return false
	return true



func _migrate_block_cut_routes() -> bool:
	var geometry := _state.geometry
	var mined := _state.mined_count()
	var last_work := geometry.miner_work_position(mined - 1, mined) if mined > 0 else geometry.quarry_mouth()
	for id in _state.worker_ids():
		var worker := _state.worker(id)
		if _state.transfer_source(id) == Owner.QUARRY or worker.fsm_state == &"return_to_quarry":
			if not _migrate_block_cut_haul(worker, last_work, mined):
				return false
		elif worker.role == State.Worker.Role.MINER:
			var routes: Array[PackedVector2Array] = []
			var position := last_work
			match worker.fsm_state:
				&"move_to_cell":
					routes.append(geometry.miner_to_next_cell(mined - 1))
				&"mine":
					position = geometry.miner_work_position(mined, mined)
				&"walk_to_lift":
					routes.append(geometry.miner_to_lift_operator(mined, last_work))
				&"return_from_lift", &"operate_lift":
					position = geometry.lift_operator_position()
					var route := geometry.miner_to_lift_operator(mined, last_work)
					route.reverse()
					routes.append(route)
				&"idle", &"exhausted":
					if worker.position.is_equal_approx(geometry.lift_operator_position()):
						position = worker.position
			if not worker.move_to_new_layout(routes, position):
				return false
	return true


func _migrate_block_cut_haul(worker: State.Worker, last_work: Vector2, mined: int) -> bool:
	var geometry := _state.geometry
	var pickups := _state.pickup_targets(worker.id)
	var cargo := _state.stock(worker.id)
	var position := worker.position
	if worker.fsm_state == &"load" and not pickups.is_empty():
		position = geometry.quarry_pickup(pickups.pop_front(), mined)
	elif worker.fsm_state == &"unload" and not cargo.is_empty():
		position = _state.raw_place(cargo[-1])

	var routes: Array[PackedVector2Array] = []
	var previous := position
	var started := worker.fsm_state in [&"load", &"unload"]
	for phase: Dictionary in worker.timing_snapshot().phases:
		var old: Array = phase.route
		if old.is_empty():
			continue
		var start := Vector2(old[0][0], old[0][1])
		var finish := Vector2(old[-1][0], old[-1][1])
		match StringName(phase.state):
			&"walk_to_pickup":
				if pickups.is_empty():
					return false
				if not started:
					if not cargo.is_empty():
						start = geometry.quarry_pickup(cargo[-1], mined)
					elif worker.role == State.Worker.Role.MINER:
						start = last_work
					else:
						start = geometry.quarry_excavation.project(start, mined)
				finish = geometry.quarry_pickup(pickups.pop_front(), mined)
			&"walk_to_storage":
				if not started and not cargo.is_empty() and start.y < 0.0:
					start = geometry.quarry_pickup(cargo[-1], mined)
			&"return_to_quarry":
				finish = last_work
		if started:
			start = previous
		routes.append(_quarry_surface_route(start, finish, mined))
		previous = finish
		started = true
	return worker.move_to_new_layout(routes, position)


func _migrate_miner() -> bool:
	var geometry := _state.geometry
	var miner := _state.worker(Owner.MINER)
	var mined := _state.mined_count()
	var position := geometry.miner_work_position(mined - 1, mined) if mined > 0 else geometry.quarry_mouth()
	if geometry.quarry_slopes != null and miner.position == geometry.lift_operator_position() \
			and miner.fsm_state in [&"idle", &"exhausted"]:
		return true
	var routes: Array[PackedVector2Array] = []
	match miner.fsm_state:
		&"move_to_cell":
			routes.append(geometry.miner_to_next_cell(mined - 1))
		&"mine":
			position = geometry.miner_work_position(mined, mined)
		&"walk_to_pickup", &"load", &"walk_to_storage", &"unload", &"return_to_quarry":
			return _migrate_haul(miner.id)
		&"walk_to_lift":
			routes.append(geometry.miner_to_lift_operator())
		&"operate_lift", &"return_from_lift":
			position = geometry.lift_operator_position()
			var route := geometry.miner_to_lift_operator()
			route.reverse()
			routes.append(route)
	return miner.move_to_new_layout(routes, position)


func _migrate_haul(worker_id: int) -> bool:
	var mined := _state.mined_count()
	var porter := _state.worker(worker_id)
	var slopes := _state.geometry.quarry_slopes
	if slopes == null:
		return true
	return porter.remap_saved_routes(
		func(_phase: StringName, route: PackedVector2Array) -> PackedVector2Array:
			return _quarry_surface_route(route[0], route[-1], mined),
		slopes.project(porter.position, mined))
