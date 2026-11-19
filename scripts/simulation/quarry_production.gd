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
				if _state.geometry.quarry_slopes != null:
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
		return slopes.route(slopes.project(start, mined), slopes.project(finish, mined), mined)
	for id in _state.worker_ids():
		var worker := _state.worker(id)
		if worker.role == State.Worker.Role.PORTER and _state.transfer_source(id) == Owner.QUARRY:
			worker.follow_quarry_surface(follow, slopes.project(worker.position, mined))
		elif worker.role == State.Worker.Role.MINER and id != worker_id and worker.fsm_state == &"idle":
			worker.position = slopes.project(worker.position, mined)


func assign_tasks() -> void:
	var ids := _state.worker_ids()
	ids.sort()
	for worker_id in ids:
		if _state.worker(worker_id).role == State.Worker.Role.PORTER:
			_assign_porter(worker_id)
	var miners := _state.worker_ids_for_role(State.Worker.Role.MINER)
	for offset in range(miners.size()):
		var index := (_state.mined_count() + offset) % miners.size()
		var miner := _state.worker(miners[index])
		if miner.fsm_state == &"idle":
			_assign_miner(miner.id)
			break


func _assign_miner(worker_id: int) -> bool:
	var miner := _state.worker(worker_id)
	if miner.fsm_state != &"idle":
		return false
	var resource_id := _state.mined_count()
	if resource_id >= State.RESOURCE_COUNT:
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
	if previous_id < 0 or _state.free_slots(Owner.QUARRY_STOCK) == 0:
		return
	var geometry := _state.geometry
	var target := -1
	var best := INF
	for id: int in _state.stock(Owner.QUARRY):
		if _state.reserved_by(id) != -1:
			continue
		var length := geometry.route_length(geometry.miner_to_pickup(previous_id, id)) \
			+ geometry.route_length(geometry.quarry_to_stock(id, previous_id + 1))
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
	miner.queue_move(&"walk_to_storage", geometry.quarry_to_stock(target, previous_id + 1), speed)
	miner.queue_work(&"unload", float(_porter_config.unloadSeconds), 1.0)
	miner.queue_move(&"return_to_quarry", geometry.quarry_stock_to_miner(previous_id), speed)


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

	var staged := _available_batch(Owner.QUARRY_STOCK, Owner.RAW)
	if geometry.has_custom_blueprint():
		staged.sort()
		var earliest_quarry := State.RESOURCE_COUNT
		for resource_id: int in _state.stock(Owner.QUARRY):
			if _state.reserved_by(resource_id) == -1 and _eligible_raw_resource(resource_id):
				earliest_quarry = mini(earliest_quarry, resource_id)
		var earlier_staged: Array[int] = []
		for resource_id: int in staged:
			if resource_id < earliest_quarry:
				earlier_staged.append(resource_id)
		staged = earlier_staged
	staged = _reserve_raw_batch(worker_id, staged, Owner.QUARRY_STOCK)
	if not staged.is_empty():
		_queue_stock_haul(porter, staged, geometry.quarry_stock(), geometry.raw_storage(), true)
		return

	# Reserve the whole trip before the miner can claim any of its stones.
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
	if not porter.queue_move(&"walk_to_pickup", pickup_route, empty_speed):
		_state.cancel_transfer(worker_id)
		return
	porter.queue_work(&"load", load_seconds, 1.0)
	for index in range(1, batch.size()):
		var route := geometry.quarry_between_pickups(batch[index - 1], batch[index], mined)
		porter.queue_move(&"walk_to_pickup", route, _loaded_speed(batch.slice(0, index)))
		porter.queue_work(&"load", load_seconds, 1.0)
	var approach := geometry.quarry_to_raw(batch[-1], mined)
	approach.append(_state.raw_place(batch[0]))
	porter.queue_move(&"walk_to_storage", approach, _loaded_speed(batch))
	for index in range(batch.size()):
		if index > 0:
			porter.queue_move(&"walk_to_storage", [_state.raw_place(batch[index - 1]), _state.raw_place(batch[index])], _loaded_speed(batch.slice(index)))
		porter.queue_work(&"unload", unload_seconds, 1.0)
	porter.queue_move(&"return_to_raw_storage",
		[_state.raw_place(batch[-1]), geometry.raw_storage()], empty_speed)


func _available_batch(source: int, destination: int) -> Array[int]:
	var limit := mini(_state.porter_capacity, _state.free_slots(destination))
	var batch: Array[int] = []
	for resource_id: int in _state.stock(source):
		if batch.size() >= limit:
			break
		if _state.reserved_by(resource_id) == -1 and (destination != Owner.RAW or _eligible_raw_resource(resource_id)):
			batch.append(resource_id)
	return batch


func _eligible_raw_resource(resource_id: int) -> bool:
	return not _state.geometry.has_custom_blueprint() or resource_id < _state.target_count()


func _reserve_raw_batch(worker_id: int, candidates: Array[int], source: int = -1) -> Array[int]:
	for count in range(candidates.size(), 0, -1):
		var batch := candidates.slice(0, count)
		if _state.reserve_transfer(worker_id, batch, source):
			return batch
	return []


func _queue_stock_haul(porter: State.Worker, resources: Array[int], source: Vector2, destination: Vector2, raw_slots := false) -> void:
	porter.queue_move(&"walk_to_pickup", [porter.position, source], float(_porter_config.emptySpeed))
	for i in range(resources.size()):
		porter.queue_work(&"load", float(_porter_config.loadSeconds), 1.0)
	var first := _state.raw_place(resources[0]) if raw_slots else destination
	porter.queue_move(&"walk_to_storage", [source, first], _loaded_speed(resources))
	for i in range(resources.size()):
		if raw_slots and i > 0:
			porter.queue_move(&"walk_to_storage", [_state.raw_place(resources[i - 1]), _state.raw_place(resources[i])], _loaded_speed(resources.slice(i)))
		porter.queue_work(&"unload", float(_porter_config.unloadSeconds), 1.0)
	if raw_slots:
		porter.queue_move(&"return_to_raw_storage",
			[_state.raw_place(resources[-1]), _state.geometry.raw_storage()], float(_porter_config.emptySpeed))


func _loaded_speed(resources: Array[int]) -> float:
	var multiplier := clampf(float(_porter_config.get("extraItemSpeedMultiplier", 0.94)), 0.9, 1.0)
	var block_multiplier := 1.0
	for resource_id in resources:
		block_multiplier = maxf(block_multiplier, _state.geometry.block_multiplier(resource_id))
	return float(_porter_config.loadedSpeed) * pow(multiplier, resources.size() - 1) / block_multiplier


func migrate_saved_routes() -> bool:
	if not _migrate_miner():
		return false
	for worker_id in _state.worker_ids():
		if worker_id >= Owner.FIRST_PORTER and _state.transfer_source(worker_id) == Owner.QUARRY \
				and not _migrate_haul(worker_id):
			return false
	return true


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
			if miner.fsm_state in [&"walk_to_pickup", &"load", &"walk_to_storage"]:
				var pending := _state.task_resource_ids(Owner.MINER)
				if pending.size() != 1 or mined == 0:
					return false
				if miner.fsm_state == &"walk_to_pickup":
					routes.append(geometry.miner_to_pickup(mined - 1, pending[0]))
				position = geometry.quarry_pickup(pending[0], mined)
				routes.append(geometry.quarry_to_stock(pending[0], mined))
			else:
				position = geometry.quarry_stock()
			routes.append(geometry.quarry_stock_to_miner(mined - 1))
		&"walk_to_lift":
			routes.append(geometry.miner_to_lift_operator())
		&"operate_lift", &"return_from_lift":
			position = geometry.lift_operator_position()
			var route := geometry.miner_to_lift_operator()
			route.reverse()
			routes.append(route)
	return miner.move_to_new_layout(routes, position)


func _migrate_haul(worker_id: int) -> bool:
	var geometry := _state.geometry
	var mined := _state.mined_count()
	var porter := _state.worker(worker_id)
	var pending := _state.task_resource_ids(worker_id)
	var targets := _state.pickup_targets(worker_id)
	var routes: Array[PackedVector2Array] = []
	var position := geometry.raw_storage()
	var previous := pending.size() - targets.size() - 1
	if porter.fsm_state == &"load":
		if targets.is_empty():
			return false
		position = geometry.quarry_pickup(targets[0], mined)
		previous += 1
	if porter.fsm_state in [&"walk_to_pickup", &"load"]:
		for index in range(previous + 1, pending.size()):
			var route: PackedVector2Array
			if index == 0:
				route = geometry.quarry_to_raw(pending[0], mined)
				route.reverse()
			else:
				route = geometry.quarry_between_pickups(pending[index - 1], pending[index], mined)
			routes.append(route)
	if porter.fsm_state != &"unload":
		routes.append(geometry.quarry_to_raw(pending[-1], mined))
	return porter.move_to_new_layout(routes, position)
