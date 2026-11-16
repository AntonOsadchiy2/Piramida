extends RefCounted

const Values = preload("res://scripts/domain/snapshot_values.gd")
const Geometry = preload("res://scripts/domain/world_geometry.gd")
const Worker = preload("res://scripts/domain/worker_state.gd")
const RESOURCE_COUNT := 900
const MAX_PORTER_CAPACITY := 8

# Cargo owners share their IDs with the respective workers.
enum Owner { UNMINED, QUARRY, RAW, FINISHED, PLATFORM, PLACED,
	MINER, DRESSER, LIFT, BUILDER, FIRST_PORTER, WORKSHOP_OUTPUT = 100, QUARRY_STOCK }

class TransferTask:
	var source: int
	var destination: int
	var pending: Array[int] = []


var geometry: Geometry
var currency: int # Retained for compatibility with existing wallpaper snapshots.
var upgrade_levels: Dictionary[String, int] = {}
var porter_count: int = 0
var _porter_limit: int
var current_row: int = 0
var row_start: int = 0
var completed_rows: int = 0
var finished: bool = false
var porter_capacity: int = 1:
	set(value):
		if value >= porter_capacity and value <= MAX_PORTER_CAPACITY:
			porter_capacity = value

var _owners: Array[int] = []
var _stocks: Dictionary[int, Array] = {}
var _capacities: Dictionary[int, int] = {}
var _workers: Dictionary[int, Worker] = {}
var _tasks: Dictionary[int, TransferTask] = {}


func _init(balance: Dictionary) -> void:
	geometry = Geometry.new(balance)
	porter_capacity = clampi(int(balance.workers.porter.get("capacity", 1)), 1, MAX_PORTER_CAPACITY)
	var storages: Dictionary = balance.storages
	_capacities = {
		Owner.UNMINED: RESOURCE_COUNT,
		Owner.QUARRY: int(storages.quarryReadyCapacity),
		Owner.QUARRY_STOCK: int(storages.quarryStockCapacity),
		Owner.RAW: int(storages.raw),
		Owner.WORKSHOP_OUTPUT: int(storages.workshopOutput),
		Owner.FINISHED: int(storages.finished),
		Owner.PLATFORM: int(storages.platform),
		Owner.PLACED: RESOURCE_COUNT,
	}
	for owner in _capacities:
		_stocks[owner] = []
	for resource_id in range(RESOURCE_COUNT):
		_owners.append(Owner.UNMINED)
		_stocks[Owner.UNMINED].append(resource_id)

	_workers[Owner.MINER] = Worker.new(Owner.MINER, Worker.Role.MINER, geometry.quarry_mouth())
	_workers[Owner.DRESSER] = Worker.new(Owner.DRESSER, Worker.Role.DRESSER, geometry.workshop())
	_workers[Owner.LIFT] = Worker.new(Owner.LIFT, Worker.Role.LIFT, geometry.finished_storage())
	_workers[Owner.BUILDER] = Worker.new(Owner.BUILDER, Worker.Role.BUILDER, geometry.platform(0))
	_stocks[Owner.MINER] = []
	_capacities[Owner.MINER] = 1
	for worker_id in [Owner.DRESSER, Owner.LIFT, Owner.BUILDER]:
		_stocks[worker_id] = []
		_capacities[worker_id] = 1
	_porter_limit = 1
	for index in range(clampi(int(balance.workers.porter.count), 1, _porter_limit)):
		add_porter()


func can_add_porter() -> bool:
	return porter_count < _porter_limit


func add_porter() -> bool:
	if not can_add_porter():
		return false
	var worker_id := Owner.FIRST_PORTER + porter_count
	var porter := Worker.new(worker_id, Worker.Role.PORTER, geometry.raw_storage())
	if porter_count > 0:
		porter.speed_multiplier = worker(Owner.FIRST_PORTER).speed_multiplier
	_workers[worker_id] = porter
	_stocks[worker_id] = []
	porter_count += 1
	return true


func worker(worker_id: int) -> Worker:
	return _workers.get(worker_id)


func worker_ids() -> Array[int]:
	return _workers.keys()


func lift_operator_id() -> int:
	for id in _workers:
		if _workers[id].fsm_state in [&"walk_to_lift", &"operate_lift"]:
			return id
	return -1


func stock(owner: int) -> Array:
	return _stocks.get(owner, []).duplicate()


func stock_count(owner: int) -> int:
	return _stocks.get(owner, []).size()


func free_slots(owner: int) -> int:
	return _capacities[owner] - stock_count(owner) - incoming_count(owner)


func mined_count() -> int:
	return RESOURCE_COUNT - stock_count(Owner.UNMINED)


func placed_count() -> int:
	return stock_count(Owner.PLACED)


func platform_position() -> Vector2:
	var builder := worker(Owner.BUILDER)
	if builder.fsm_state != &"rebuild_platform":
		return geometry.platform(current_row)

	var route := geometry.platform_to_next_row(current_row)
	var fraction := 1.0 - builder.remaining_work / geometry.rebuild_seconds()
	if geometry.has_pyramid_ramp():
		return route[0].lerp(route[-1], fraction)
	var distance := geometry.route_length(route) * fraction
	var vertical := route[0].distance_to(route[1])
	if distance < vertical:
		return route[0].move_toward(route[1], distance)
	return route[1].move_toward(route[2], distance - vertical)


func resource_record(resource_id: int) -> Dictionary:
	if not _valid_id(resource_id):
		return {}
	var cell := geometry.quarry_grid_cell(resource_id)
	return {
		"id": resource_id,
		"source_layer": cell.y,
		"source_index": cell.x + geometry.quarry_layers() - 1,
		"owner": _owners[resource_id],
		"reserved_by": reserved_by(resource_id),
	}


func reserved_by(resource_id: int) -> int:
	for worker_id in _tasks:
		if resource_id in _tasks[worker_id].pending:
			return worker_id
	return -1


func incoming_count(owner: int) -> int:
	var count := 0
	for task in _tasks.values():
		if task.destination == owner:
			count += task.pending.size()
	return count


func task_resource_ids(worker_id: int) -> Array[int]:
	if not _tasks.has(worker_id):
		return []
	return _tasks[worker_id].pending.duplicate()


func transfer_source(worker_id: int) -> int:
	var task: TransferTask = _tasks.get(worker_id)
	return task.source if task != null else -1


func pickup_targets(worker_id: int) -> Array[int]:
	var targets: Array[int] = []
	var task: TransferTask = _tasks.get(worker_id)
	if task != null:
		for resource_id in task.pending:
			if _owners[resource_id] == task.source:
				targets.append(resource_id)
	return targets


# Commit both the resource claim and the destination slots after validating the whole batch.
func reserve_transfer(worker_id: int, resource_ids: Array[int], source_owner: int = -1) -> bool:
	if not _workers.has(worker_id) or _tasks.has(worker_id) or resource_ids.is_empty():
		return false
	if resource_ids.size() > _batch_capacity(worker_id):
		return false

	var route := _route(worker_id, source_owner)
	var source := route.x
	var destination := route.y
	if destination < 0 or resource_ids.size() > free_slots(destination):
		return false

	var seen := {}
	for resource_id in resource_ids:
		if not _valid_id(resource_id) or _owners[resource_id] != source:
			return false
		if seen.has(resource_id) or reserved_by(resource_id) != -1:
			return false
		if source == Owner.UNMINED and resource_id != mined_count():
			return false
		seen[resource_id] = true

	var task := TransferTask.new()
	task.source = source
	task.destination = destination
	task.pending = resource_ids.duplicate()
	_tasks[worker_id] = task
	return true


func pick_up(worker_id: int, resource_id: int) -> bool:
	var task: TransferTask = _tasks.get(worker_id)
	if task == null or task.source == Owner.UNMINED or resource_id not in task.pending:
		return false
	if _owners[resource_id] != task.source or stock_count(worker_id) >= _batch_capacity(worker_id):
		return false
	_move(resource_id, task.source, worker_id)
	return true


func deliver(worker_id: int, resource_id: int) -> bool:
	var task: TransferTask = _tasks.get(worker_id)
	if task == null or resource_id not in task.pending:
		return false
	var expected_owner := Owner.UNMINED if task.source == Owner.UNMINED else worker_id
	if _owners[resource_id] != expected_owner:
		return false
	_move(resource_id, expected_owner, task.destination)
	task.pending.erase(resource_id)
	if task.pending.is_empty():
		_tasks.erase(worker_id)
	return true


# Cargo already picked up must be delivered before cancelling the remaining claims.
func cancel_transfer(worker_id: int) -> bool:
	if stock_count(worker_id) != 0:
		return false
	return _tasks.erase(worker_id)


func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if _owners.size() != RESOURCE_COUNT or geometry.quarry_count() != RESOURCE_COUNT:
		errors.append("Expected %d resources." % RESOURCE_COUNT)

	var seen := {}
	for owner in _stocks:
		var capacity: int = _capacities.get(owner, porter_capacity)
		if stock_count(owner) + incoming_count(owner) > capacity:
			errors.append("Capacity exceeded for owner %d." % owner)
		for resource_id in _stocks[owner]:
			if not _valid_id(resource_id):
				errors.append("Invalid resource ID %s." % resource_id)
				continue
			if seen.has(resource_id) or _owners[resource_id] != owner:
				errors.append("Inconsistent ownership for resource %d." % resource_id)
			seen[resource_id] = true
			if _workers.has(owner) and reserved_by(resource_id) != owner:
				errors.append("Cargo %d has no matching task." % resource_id)
	if seen.size() != RESOURCE_COUNT:
		errors.append("Expected %d uniquely owned resources." % RESOURCE_COUNT)

	var claimed := {}
	for worker_id in _tasks:
		var task := _tasks[worker_id]
		var route := _route(worker_id, task.source, task.destination)
		if not _workers.has(worker_id) or task.source != route.x or task.destination != route.y:
			errors.append("Invalid route or worker for task %d." % worker_id)
		if task.pending.is_empty() or task.pending.size() > _batch_capacity(worker_id):
			errors.append("Invalid batch size for task %d." % worker_id)
		for resource_id in task.pending:
			if not _valid_id(resource_id):
				errors.append("Invalid resource ID in task %d." % worker_id)
				continue
			var owner := _owners[resource_id]
			if claimed.has(resource_id) or (owner != task.source and owner != worker_id):
				errors.append("Inconsistent claim for resource %d." % resource_id)
			if task.source == Owner.UNMINED and resource_id != mined_count():
				errors.append("Miner task does not target the next quarry cell.")
			claimed[resource_id] = true
	return errors


func _valid_id(resource_id: int) -> bool:
	return resource_id >= 0 and resource_id < RESOURCE_COUNT and resource_id < _owners.size()


func _batch_capacity(worker_id: int) -> int:
	return porter_capacity if worker_id >= Owner.FIRST_PORTER else 1


func _route(worker_id: int, source: int = -1, destination: int = -1) -> Vector2i:
	var route: Vector2i
	match worker_id:
		Owner.MINER:
			route = Vector2i(Owner.QUARRY, Owner.QUARRY_STOCK) if source == Owner.QUARRY \
				else Vector2i(Owner.UNMINED, Owner.QUARRY)
		Owner.DRESSER:
			route = Vector2i(Owner.RAW, Owner.FINISHED if destination == Owner.FINISHED else Owner.WORKSHOP_OUTPUT)
		Owner.LIFT:
			route = Vector2i(Owner.FINISHED, Owner.PLATFORM)
		Owner.BUILDER:
			if source == Owner.WORKSHOP_OUTPUT:
				route = Vector2i(source, Owner.PLACED if current_row == 0 else Owner.FINISHED)
			else:
				route = Vector2i(Owner.FINISHED if source == Owner.FINISHED and current_row == 0 else Owner.PLATFORM, Owner.PLACED)
		_:
			route = Vector2i(Owner.WORKSHOP_OUTPUT, Owner.FINISHED) if source == Owner.WORKSHOP_OUTPUT \
				else Vector2i(Owner.QUARRY, Owner.RAW)
			if source == Owner.QUARRY_STOCK:
				route = Vector2i(Owner.QUARRY_STOCK, Owner.RAW)
	if (source >= 0 and route.x != source) or (destination >= 0 and route.y != destination):
		return Vector2i(-1, -1)
	return route


func _move(resource_id: int, source: int, destination: int) -> void:
	_stocks[source].erase(resource_id)
	_stocks[destination].append(resource_id)
	_owners[resource_id] = destination

func to_dict() -> Dictionary:
	var stocks := {}
	for owner in _stocks:
		stocks[str(owner)] = stock(owner)
	var tasks := {}
	var transfer_routes := {}
	for id in _tasks:
		tasks[str(id)] = task_resource_ids(id)
		var task := _tasks[id]
		transfer_routes[str(id)] = [task.source, task.destination]
	return {
		"currency": currency, "upgrade_levels": upgrade_levels.duplicate(),
		"porter_count": porter_count, "porter_capacity": porter_capacity,
		"current_row": current_row, "row_start": row_start, "completed_rows": completed_rows,
		"finished": finished, "stocks": stocks, "tasks": tasks, "transfer_routes": transfer_routes,
	}


# Called only on a fresh candidate. Ownership and incoming reservations are derived.
func restore_snapshot(data: Dictionary, timings: Array, balance: Dictionary) -> bool:
	var rows := int(balance.world.pyramidRows)
	var limits := {
		"currency": 9007199254740991, "porter_count": _porter_limit,
		"porter_capacity": MAX_PORTER_CAPACITY, "current_row": rows - 1,
		"row_start": RESOURCE_COUNT, "completed_rows": rows,
	}
	for key in limits:
		if not Values.integer(data.get(key), limits[key]):
			return false
	if data.porter_count < porter_count or data.porter_capacity < porter_capacity \
			or not data.get("finished") is bool or not data.get("upgrade_levels") is Dictionary \
			or not data.get("stocks") is Dictionary or not data.get("tasks") is Dictionary:
		return false
	for code in data.upgrade_levels:
		var level: Variant = data.upgrade_levels[code]
		if not balance.upgrades.speed.has(code) or not Values.integer(level, int(balance.upgrades.maxSpeedLevel)) or level < 1:
			return false
		upgrade_levels[code] = int(level)
	while porter_count < data.porter_count:
		add_porter()
	porter_capacity = int(data.porter_capacity)
	currency = int(data.currency)
	current_row = int(data.current_row)
	row_start = int(data.row_start)
	completed_rows = int(data.completed_rows)
	finished = data.finished
	var routes: Variant = data.get("transfer_routes", {})
	if not routes is Dictionary or not _restore_stocks(data.stocks) \
			or not _restore_tasks(data.tasks, routes) or not validate().is_empty():
		return false
	var expected_start := 0
	for row in range(current_row):
		expected_start += geometry.row_size(row)
	var row_end := expected_start + geometry.row_size(current_row)
	if row_start != expected_start or placed_count() < row_start or placed_count() > row_end \
			or completed_rows != current_row + int(placed_count() == row_end) \
			or finished != (placed_count() == RESOURCE_COUNT):
		return false
	for id in range(RESOURCE_COUNT):
		if (_owners[id] == Owner.UNMINED) != (id >= mined_count()):
			return false
	return _restore_workers(timings, balance)


func _restore_stocks(stocks: Dictionary) -> bool:
	# Older saves delivered workshop output directly to the brick stockpile.
	var optional := [Owner.WORKSHOP_OUTPUT, Owner.MINER, Owner.QUARRY_STOCK]
	var missing := optional.filter(func(owner): return not stocks.has(str(owner)))
	if stocks.size() != _stocks.size() - missing.size():
		return false
	_owners.fill(-1)
	for owner in _stocks:
		if owner in missing:
			continue
		var ids: Variant = stocks.get(str(owner))
		if not ids is Array:
			return false
		_stocks[owner].clear()
		for id in ids:
			if not Values.integer(id, RESOURCE_COUNT - 1) or _owners[int(id)] != -1:
				return false
			_owners[int(id)] = owner
			_stocks[owner].append(int(id))
	return true


func _restore_tasks(tasks: Dictionary, routes: Dictionary) -> bool:
	for key in tasks:
		if not key is String or not key.is_valid_int():
			return false
		var id := int(key)
		if str(id) != key or not _workers.has(id) or not tasks[key] is Array:
			return false
		var task := TransferTask.new()
		var route := _route(id, -1, Owner.FINISHED if id == Owner.DRESSER else -1)
		if routes.has(key):
			var endpoints: Variant = routes[key]
			if not endpoints is Array or endpoints.size() != 2 \
					or not Values.integer(endpoints[0], Owner.QUARRY_STOCK) \
					or not Values.integer(endpoints[1], Owner.QUARRY_STOCK):
				return false
			route = _route(id, int(endpoints[0]), int(endpoints[1]))
		if route.x < 0:
			return false
		task.source = route.x
		task.destination = route.y
		for resource_id in tasks[key]:
			if not Values.integer(resource_id, RESOURCE_COUNT - 1):
				return false
			task.pending.append(int(resource_id))
		_tasks[id] = task
	return true


func _restore_workers(timings: Array, balance: Dictionary) -> bool:
	var states := [
		["move_to_cell", "mine", "walk_to_pickup", "load", "walk_to_storage", "unload",
			"return_to_quarry"], ["process_brick"], ["lift_brick"],
		["walk_to_brick", "place_brick", "return_to_platform", "rebuild_platform", "climb_to_platform",
			"walk_to_workshop", "walk_to_lift_base", "unload_at_lift", "walk_to_lift", "operate_lift", "return_from_lift"],
		["walk_to_pickup", "load", "walk_to_storage", "unload", "return_to_raw_storage"],
	]
	for role in [Worker.Role.MINER, Worker.Role.DRESSER, Worker.Role.PORTER]:
		states[role].append_array(["walk_to_lift", "operate_lift", "return_from_lift"])
	var speed_codes := ["MINER_SPEED", "DRESSER_SPEED", "", "BUILDER_SPEED", "PORTER_SPEED"]
	var seen := {}
	var lift_operator := -1
	for timing in timings:
		if not timing is Dictionary or not Values.integer(timing.get("id"), Owner.FIRST_PORTER + _porter_limit - 1):
			return false
		var id := int(timing.id)
		var agent := worker(id)
		if agent == null or seen.has(id) or not agent.restore_timing(timing, states[agent.role]):
			return false
		var code: String = speed_codes[agent.role]
		var multiplier := 1.0
		if upgrade_levels.has(code):
			multiplier = pow(float(balance.upgrades.speed[code].multiplier), upgrade_levels[code] - 1)
		if not is_equal_approx(agent.speed_multiplier, multiplier):
			return false
		var requires_task := agent.fsm_state in [&"move_to_cell", &"mine", &"process_brick", &"lift_brick",
			&"walk_to_brick", &"place_brick", &"walk_to_pickup", &"load", &"walk_to_storage", &"unload",
			&"walk_to_workshop", &"walk_to_lift_base", &"unload_at_lift"]
		if requires_task != _tasks.has(id):
			return false
		if requires_task and id in [Owner.DRESSER, Owner.LIFT, Owner.BUILDER]:
			var expected_cargo := 0 if agent.fsm_state == &"walk_to_workshop" else 1
			if stock_count(id) != expected_cargo:
				return false
			if agent.fsm_state in [&"walk_to_workshop", &"walk_to_lift_base", &"unload_at_lift"] \
					and transfer_source(id) != Owner.WORKSHOP_OUTPUT:
				return false
		if requires_task and (id >= Owner.FIRST_PORTER or (id == Owner.MINER and transfer_source(id) == Owner.QUARRY)):
			var loads := 0
			var unloads := 0
			for phase in timing.phases:
				loads += int(phase.state == "load")
				unloads += int(phase.state == "unload")
			if loads != pickup_targets(id).size() or unloads != _tasks[id].pending.size():
				return false
		if agent.fsm_state == &"rebuild_platform" and (current_row + 1 != completed_rows or finished):
			return false
		if agent.fsm_state == &"exhausted" and mined_count() != RESOURCE_COUNT:
			return false
		if id == Owner.MINER and agent.fsm_state in [&"walk_to_lift", &"operate_lift", &"return_from_lift"] \
				and mined_count() != RESOURCE_COUNT:
			return false
		if agent.fsm_state in [&"walk_to_lift", &"operate_lift"]:
			if lift_operator != -1:
				return false
			lift_operator = id
		seen[id] = true
	return seen.size() == _workers.size()
