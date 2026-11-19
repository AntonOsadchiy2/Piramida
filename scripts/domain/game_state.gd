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
var scaffold_sections: Array = [] # Derived from placed masonry; rebuilt after load.
var currency: int # Retained for compatibility with existing wallpaper snapshots.
var upgrade_levels: Dictionary[String, int] = {}
var porter_count: int = 0
var _porter_limit: int
var active_builder_id: int = Owner.BUILDER
var next_dresser_index: int = 0
var current_row: int = 0
var row_start: int = 0
var completed_rows: int = 0
var finished: bool = false
var delivery_point := Vector2.INF # Position of the current upper scaffold stockpile.
var porter_capacity: int = 1:
	set(value):
		if value >= porter_capacity and value <= MAX_PORTER_CAPACITY:
			porter_capacity = value

var _owners: Array[int] = []
var _stocks: Dictionary[int, Array] = {}
var _capacities: Dictionary[int, int] = {}
var _workers: Dictionary[int, Worker] = {}
var _tasks: Dictionary[int, TransferTask] = {}
var _raw_places: Dictionary[int, float] = {}
const RAW_GAP := 0.06


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
	for role_config in [
		[Worker.Role.MINER, 20, "miner", geometry.quarry_mouth()],
		[Worker.Role.DRESSER, 30, "dresser", geometry.workshop()],
		[Worker.Role.BUILDER, 40, "builder", geometry.platform(0)],
	]:
		var count := clampi(int(balance.workers[role_config[2]].get("count", 1)), 1, 4)
		for index in range(count - 1):
			var id: int = role_config[1] + index
			_workers[id] = Worker.new(id, role_config[0], role_config[3])
			_stocks[id] = []
			_capacities[id] = 1
	_porter_limit = clampi(int(balance.workers.porter.count), 1, 4)
	for index in range(_porter_limit):
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


static func role_for_id(id: int) -> Worker.Role:
	if id == Owner.MINER or id in range(20, 23):
		return Worker.Role.MINER
	if id == Owner.DRESSER or id in range(30, 33):
		return Worker.Role.DRESSER
	if id == Owner.BUILDER or id in range(40, 43):
		return Worker.Role.BUILDER
	if id == Owner.LIFT:
		return Worker.Role.LIFT
	return Worker.Role.PORTER


func worker_ids_for_role(role: Worker.Role) -> Array[int]:
	var ids: Array[int] = []
	for id in _workers:
		if _workers[id].role == role:
			ids.append(id)
	ids.sort()
	return ids


func lift_operator_id() -> int:
	for id in _workers:
		if _workers[id].fsm_state in [&"walk_to_lift", &"operate_lift"]:
			return id
	return -1


func stock(owner: int) -> Array:
	return _stocks.get(owner, []).duplicate()


func stock_count(owner: int) -> int:
	return _stocks.get(owner, []).size()


func raw_place(resource_id: int) -> Vector2:
	return Vector2(_raw_places.get(resource_id, geometry.raw_storage().x), 0.0)


func _find_raw_place(resource_id: int, places: Dictionary[int, float]) -> float:
	var bounds := geometry.raw_storage_bounds()
	var width := geometry.raw_block_width(resource_id)
	var left := bounds.x
	var ordered: Array[int] = places.keys()
	ordered.sort_custom(func(a: int, b: int) -> bool: return places[a] < places[b])
	for other_id in ordered:
		var other_width := geometry.raw_block_width(other_id)
		var occupied_left: float = places[other_id] - other_width * 0.5
		if left + width + RAW_GAP <= occupied_left:
			break
		left = maxf(left, places[other_id] + other_width * 0.5 + RAW_GAP)
	var center := ceilf((left + width * 0.5) * 100.0) / 100.0
	return center if center + width * 0.5 <= bounds.y + 0.0001 else NAN


func free_slots(owner: int) -> int:
	return _capacities[owner] - stock_count(owner) - incoming_count(owner)


func mined_count() -> int:
	return RESOURCE_COUNT - stock_count(Owner.UNMINED)


func placed_count() -> int:
	return stock_count(Owner.PLACED)


func placed_surface_snapshot() -> Dictionary:
	if geometry.has_custom_blueprint():
		return geometry.placed_surface_snapshot(stock(Owner.PLACED))
	var placement_ids: Array[int] = []
	for index in range(placed_count()):
		placement_ids.append(index)
	return geometry.placed_surface_snapshot(placement_ids)


func target_count() -> int:
	var total := 0
	for row in range(geometry.row_count()):
		total += geometry.row_size(row)
	return total


func platform_position() -> Vector2:
	var builder := worker(active_builder_id)
	if geometry.has_custom_blueprint():
		if current_row == 0:
			return geometry.platform(0)
		return delivery_point if delivery_point.is_finite() else builder.position
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
		"size": geometry.block_size_for_resource(resource_id),
		"type": "stone",
		"source_layer": cell.y,
		"source_index": cell.x + geometry.quarry_layers() - 1,
		"owner": _owners[resource_id],
		"reserved_by": reserved_by(resource_id),
	}


func owner_of(resource_id: int) -> int:
	return _owners[resource_id] if _valid_id(resource_id) else -1


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
	if destination == Owner.WORKSHOP_OUTPUT and stock_count(destination) + incoming_count(destination) > 0:
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

	var places := _raw_places.duplicate()
	if destination == Owner.RAW:
		for resource_id in resource_ids:
			var center := _find_raw_place(resource_id, places)
			if not is_finite(center):
				return false
			places[resource_id] = center

	var task := TransferTask.new()
	task.source = source
	task.destination = destination
	task.pending = resource_ids.duplicate()
	_tasks[worker_id] = task
	if destination == Owner.RAW:
		_raw_places = places
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
	var task: TransferTask = _tasks.get(worker_id)
	if task != null and task.destination == Owner.RAW:
		for resource_id in task.pending:
			_raw_places.erase(resource_id)
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
	var expected_raw := {}
	for resource_id in stock(Owner.RAW):
		expected_raw[resource_id] = true
	for task in _tasks.values():
		if task.destination == Owner.RAW:
			for resource_id in task.pending:
				expected_raw[resource_id] = true
	# Legacy snapshots can contain more raw blocks than the visible strip can hold.
	# Those blocks keep their old fallback position until the dresser consumes them;
	# every new delivery still has to reserve a physical place below.
	if _raw_places.size() > expected_raw.size():
		errors.append("Raw storage has more places than stock and claims.")
	for resource_id in _raw_places:
		if not expected_raw.has(resource_id):
			errors.append("Orphan raw storage place for %d." % resource_id)
			continue
		var width := geometry.raw_block_width(resource_id)
		var center: float = _raw_places[resource_id]
		var bounds := geometry.raw_storage_bounds()
		if center - width * 0.5 < bounds.x - 0.0001 or center + width * 0.5 > bounds.y + 0.0001:
			errors.append("Raw block %d extends outside storage." % resource_id)
		for other_id in _raw_places:
			if other_id >= resource_id:
				continue
			var distance: float = absf(center - _raw_places[other_id])
			if distance + 0.0001 < (width + geometry.raw_block_width(other_id)) * 0.5 + RAW_GAP:
				errors.append("Raw storage places overlap: %d and %d." % [resource_id, other_id])
	return errors


func _valid_id(resource_id: int) -> bool:
	return resource_id >= 0 and resource_id < RESOURCE_COUNT and resource_id < _owners.size()


func _batch_capacity(worker_id: int) -> int:
	return porter_capacity if _workers.has(worker_id) and _workers[worker_id].role == Worker.Role.PORTER else 1


func _route(worker_id: int, source: int = -1, destination: int = -1) -> Vector2i:
	if not _workers.has(worker_id):
		return Vector2i(-1, -1)
	var route: Vector2i
	match _workers[worker_id].role:
		Worker.Role.MINER:
			route = Vector2i(Owner.QUARRY, Owner.QUARRY_STOCK) if source == Owner.QUARRY \
				else Vector2i(Owner.UNMINED, Owner.QUARRY)
		Worker.Role.DRESSER:
			route = Vector2i(Owner.QUARRY_STOCK if source == Owner.QUARRY_STOCK else Owner.RAW,
				Owner.FINISHED if destination == Owner.FINISHED else Owner.WORKSHOP_OUTPUT)
		Worker.Role.LIFT:
			route = Vector2i(Owner.FINISHED, Owner.PLATFORM)
		Worker.Role.BUILDER:
			if source == Owner.WORKSHOP_OUTPUT:
				route = Vector2i(source, Owner.PLACED if current_row == 0 else Owner.FINISHED)
			else:
				route = Vector2i(Owner.FINISHED if source == Owner.FINISHED and current_row == 0 else Owner.PLATFORM, Owner.PLACED)
		_:
			route = Vector2i(Owner.QUARRY, Owner.RAW)
			if source == Owner.QUARRY_STOCK:
				route = Vector2i(Owner.QUARRY_STOCK, Owner.RAW)
	if (source >= 0 and route.x != source) or (destination >= 0 and route.y != destination):
		return Vector2i(-1, -1)
	return route


func _move(resource_id: int, source: int, destination: int) -> void:
	_stocks[source].erase(resource_id)
	_stocks[destination].append(resource_id)
	if source == Owner.RAW:
		_raw_places.erase(resource_id)
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
	var raw_places := {}
	for resource_id in _raw_places:
		raw_places[str(resource_id)] = _raw_places[resource_id]
	return {
		"raw_places": raw_places,
		"currency": currency, "upgrade_levels": upgrade_levels.duplicate(),
		"resource_sizes": geometry.resource_sizes(),
		"porter_count": porter_count, "porter_capacity": porter_capacity,
		"current_row": current_row, "row_start": row_start, "completed_rows": completed_rows,
		"active_builder_id": active_builder_id, "next_dresser_index": next_dresser_index,
		"finished": finished, "stocks": stocks, "tasks": tasks, "transfer_routes": transfer_routes,
		"delivery_point": [delivery_point.x, delivery_point.y] if delivery_point.is_finite() else [],
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
	var saved_sizes: Variant = data.get("resource_sizes", geometry.resource_sizes())
	if not saved_sizes is Array or saved_sizes.size() != RESOURCE_COUNT:
		return false
	for resource_id in range(RESOURCE_COUNT):
		if not Values.integer(saved_sizes[resource_id], 4) or int(saved_sizes[resource_id]) != geometry.block_size_for_resource(resource_id):
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
	var saved_builder: Variant = data.get("active_builder_id", Owner.BUILDER)
	if not Values.integer(saved_builder, 42) or not _workers.has(int(saved_builder)) \
			or _workers[int(saved_builder)].role != Worker.Role.BUILDER:
		return false
	active_builder_id = int(saved_builder)
	var saved_dresser: Variant = data.get("next_dresser_index", 0)
	var dresser_count := worker_ids_for_role(Worker.Role.DRESSER).size()
	if not Values.integer(saved_dresser, dresser_count - 1):
		return false
	next_dresser_index = int(saved_dresser)
	row_start = int(data.row_start)
	completed_rows = int(data.completed_rows)
	finished = data.finished
	var saved_delivery: Variant = data.get("delivery_point", [])
	if not saved_delivery is Array or saved_delivery.size() not in [0, 2]:
		return false
	if saved_delivery.size() == 2:
		if not (saved_delivery[0] is float or saved_delivery[0] is int) \
				or not (saved_delivery[1] is float or saved_delivery[1] is int):
			return false
		delivery_point = Vector2(saved_delivery[0], saved_delivery[1])
		if not delivery_point.is_finite():
			return false
	var routes: Variant = data.get("transfer_routes", {})
	if not routes is Dictionary or not _restore_stocks(data.stocks) \
			or not _restore_tasks(data.tasks, routes) or not _restore_raw_places(data.get("raw_places", {})) \
			or not validate().is_empty():
		return false
	var expected_start := 0
	for row in range(current_row):
		expected_start += geometry.row_size(row)
	var row_end := expected_start + geometry.row_size(current_row)
	if row_start != expected_start or placed_count() < row_start or placed_count() > row_end \
			or completed_rows != current_row + int(placed_count() == row_end) \
			or finished != (placed_count() == target_count()):
		return false
	if saved_delivery.is_empty() and geometry.has_custom_blueprint() \
			and current_row > 0 and stock_count(Owner.PLATFORM) > 0:
		# The old stockpile remains at its saved physical location until collected.
		delivery_point = geometry.platform(current_row)
	for id in range(RESOURCE_COUNT):
		if (_owners[id] == Owner.UNMINED) != (id >= mined_count()):
			return false
	var workers_restored := _restore_workers(timings, balance)
	return workers_restored


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


func _restore_raw_places(saved: Variant) -> bool:
	if not saved is Dictionary:
		return false
	_raw_places.clear()
	if not saved.is_empty():
		for key in saved:
			if not str(key).is_valid_int() or not saved[key] is float:
				return false
			var id := int(key)
			if not _valid_id(id) or not is_finite(saved[key]):
				return false
			_raw_places[id] = float(saved[key])
		return true
	# Earlier snapshots only had count-based storage; assign stable first-fit positions.
	var pending: Array[int] = []
	for resource_id in stock(Owner.RAW):
		pending.append(resource_id)
	for task in _tasks.values():
		if task.destination == Owner.RAW:
			pending.append_array(task.pending)
	for id in pending:
		var center := _find_raw_place(id, _raw_places)
		if not is_finite(center):
			continue
		_raw_places[id] = center
	return true


func _restore_tasks(tasks: Dictionary, routes: Dictionary) -> bool:
	for key in tasks:
		if not key is String or not key.is_valid_int():
			return false
		var id := int(key)
		if str(id) != key or not _workers.has(id) or not tasks[key] is Array:
			return false
		var task := TransferTask.new()
		var route := _route(id, -1, Owner.FINISHED if _workers[id].role == Worker.Role.DRESSER else -1)
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
		["walk_to_brick", "place_brick", "return_to_platform", "rebuild_platform", "climb_to_platform", "join_platform",
			"walk_to_workshop", "walk_to_lift_base", "unload_at_lift", "walk_to_lift", "operate_lift", "return_from_lift"],
		["walk_to_pickup", "load", "walk_to_storage", "unload", "return_to_raw_storage"],
	]
	for role in [Worker.Role.MINER, Worker.Role.DRESSER, Worker.Role.PORTER]:
		states[role].append_array(["walk_to_lift", "operate_lift", "return_from_lift"])
	var speed_codes := ["MINER_SPEED", "DRESSER_SPEED", "", "BUILDER_SPEED", "PORTER_SPEED"]
	var seen := {}
	var lift_operator := -1
	for timing in timings:
		if not timing is Dictionary or not Values.integer(timing.get("id"), 42):
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
		var idle_builder_wait := agent.role == Worker.Role.BUILDER and agent.fsm_state == &"idle" \
			and _tasks.has(id)
		if requires_task != _tasks.has(id) and not idle_builder_wait:
			return false
		if (requires_task or idle_builder_wait) and agent.role in [Worker.Role.DRESSER, Worker.Role.LIFT, Worker.Role.BUILDER]:
			var expected_cargo := 0 if agent.fsm_state == &"walk_to_workshop" else 1
			if idle_builder_wait:
				if stock_count(id) > 1 or (stock_count(id) == 0 and _tasks[id].source != Owner.WORKSHOP_OUTPUT):
					return false
				expected_cargo = stock_count(id)
			if stock_count(id) != expected_cargo:
				return false
			if agent.fsm_state in [&"walk_to_workshop", &"walk_to_lift_base", &"unload_at_lift"] \
					and transfer_source(id) != Owner.WORKSHOP_OUTPUT:
				return false
		if requires_task and (agent.role == Worker.Role.PORTER or (agent.role == Worker.Role.MINER and transfer_source(id) == Owner.QUARRY)):
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
