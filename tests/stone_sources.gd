extends SceneTree

const State = preload("res://scripts/domain/game_state.gd")
const QuarryProduction = preload("res://scripts/simulation/quarry_production.gd")
const Wallpaper = preload("res://scripts/application/wallpaper.gd")
const Simulation = preload("res://scripts/simulation/simulation_runner.gd")
const SaveService = preload("res://scripts/application/save_service.gd")
const Owner = State.Owner

var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)


func _run() -> void:
	var balance: Dictionary = Wallpaper.wallpaper_balance(
		JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json")))
	_check_shared_delivery(balance)
	_check_old_save(balance)
	if failures == 0:
		print("PASS: miner and porter share raw storage, including a migrated quarry depot")
	quit(int(failures > 0))


func _check_shared_delivery(balance: Dictionary) -> void:
	var state := State.new(balance)
	var production := QuarryProduction.new(state, balance.workers)
	for resource_id in range(int(balance.storages.quarryReadyCapacity)):
		state._move(resource_id, Owner.UNMINED, Owner.QUARRY)
	var miner := state.worker(Owner.MINER)
	var porter := state.worker(Owner.FIRST_PORTER)
	var previous := state.mined_count() - 1
	miner.position = state.geometry.miner_work_position(previous, previous + 1)
	production.assign_tasks()

	var miner_ids := state.task_resource_ids(miner.id)
	_check(miner_ids.size() == 1 and not state.task_resource_ids(porter.id).is_empty(),
		"Both workers must reserve raw slots when the quarry queue is full")
	if miner_ids.is_empty():
		return
	var stone := miner_ids[0]
	var slot := state.raw_place(stone)
	var bounds := state.geometry.raw_storage_bounds()
	_check(slot.x > bounds.x and slot.x < bounds.y and bounds.y < state.geometry.workshop().x,
		"The reserved slot must be on the left of the workshop")
	var phases: Array = miner.timing_snapshot().phases
	var unload_walk: Array = phases.filter(func(phase: Dictionary) -> bool: return phase.state == &"walk_to_storage")
	_check(unload_walk.size() == 1 and unload_walk[0].route[-1] == [slot.x, slot.y],
		"The miner must stop at the same reserved slot that receives the stone")
	for tick in range(2000):
		for worker in [miner, porter]:
			for event in worker.advance(0.1):
				production.apply_completion(event)
		if miner.fsm_state == &"idle" and porter.fsm_state == &"idle":
			break
	_check(state.stock_count(Owner.RAW) > 1 and state.owner_of(stone) == Owner.RAW
		and state.stock_count(Owner.QUARRY_STOCK) == 0 and state.validate().is_empty(),
		"Both workers must deliver to the shared stock")
	_check(miner.position == state.geometry.miner_work_position(previous, previous + 1),
		"The miner must return to the quarry after unloading")
	var scarce := State.new(balance)
	for resource_id in range(int(balance.storages.quarryReadyCapacity) + 4):
		scarce._move(resource_id, Owner.UNMINED, Owner.RAW if resource_id < 4 else Owner.QUARRY)
	scarce._restore_raw_places({})
	miner = scarce.worker(Owner.MINER)
	previous = scarce.mined_count() - 1
	miner.position = scarce.geometry.miner_work_position(previous, previous + 1)
	QuarryProduction.new(scarce, balance.workers).assign_tasks()
	_check(scarce.task_resource_ids(Owner.MINER).size() == 1
		and scarce.task_resource_ids(Owner.FIRST_PORTER).is_empty(),
		"A miner blocked by a full quarry must be able to claim the last free shared slot")


func _check_old_save(balance: Dictionary) -> void:
	var simulation := Simulation.new(balance, false)
	var state := simulation.state
	state._restoring_legacy_raw = true
	state._capacities[Owner.QUARRY_STOCK] = int(balance.storages.quarryStockCapacity)
	state._move(0, Owner.UNMINED, Owner.RAW)
	state._move(1, Owner.UNMINED, Owner.QUARRY_STOCK)
	state._move(2, Owner.UNMINED, Owner.QUARRY_STOCK)
	state._move(3, Owner.UNMINED, Owner.QUARRY)
	state._restore_raw_places({})
	var old_depot := state.geometry.legacy_quarry_stock()
	var old_junction := Vector2(balance.world.rawStorageX, 0)
	var miner := state.worker(Owner.MINER)
	var porter := state.worker(Owner.FIRST_PORTER)
	_check(state.reserve_transfer(miner.id, [3], Owner.QUARRY) and state.pick_up(miner.id, 3),
		"Set up old miner hauling to the quarry depot")
	_check(state.reserve_transfer(porter.id, [1], Owner.QUARRY_STOCK) and state.pick_up(porter.id, 1),
		"Set up old porter hauling from the quarry depot")
	miner.position = old_depot
	miner.queue_work(&"unload", 0.7, 1.0)
	miner.queue_move(&"return_to_quarry", [
		old_depot, state.geometry.quarry_mouth() - Vector2(State.Geometry.QUARRY_SHIFT_X, 0)], 2.0)
	miner.advance(0.2)
	porter.position = old_depot
	porter.queue_move(&"walk_to_storage", [old_depot, old_junction], 2.0)
	porter.queue_work(&"unload", 0.7, 1.0)

	var snapshot := simulation.to_dict()
	snapshot.model.erase("raw_layout")
	for key in snapshot.model.raw_places:
		snapshot.model.raw_places[key] -= State.Geometry.RAW_STORAGE_SHIFT_X
	var old_data: Dictionary = JSON.parse_string(JSON.stringify(snapshot, "", true, true))
	var restored := Simulation.from_dict(balance, old_data) as Simulation
	_check(restored != null, "The old stockpile snapshot must load")
	if restored == null:
		return
	var migrated := restored.state
	var resumed_miner := migrated.worker(miner.id)
	_check(migrated.stock_count(Owner.RAW) == 3 and migrated.stock_count(Owner.QUARRY_STOCK) == 0
		and migrated.stock(porter.id).is_empty() and migrated.task_resource_ids(porter.id).is_empty(),
		"The old depot and porter cargo must move to the shared stock exactly once")
	_check(migrated.stock(miner.id) == [3] and resumed_miner.fsm_state == &"unload"
		and resumed_miner.position == migrated.raw_place(3)
		and resumed_miner.remaining_work == miner.remaining_work,
		"The active miner unload must resume at its reserved slot")
	var saves := SaveService.new(balance, "user://stone-sources-test/save.json")
	_check(saves.save_game(restored) == OK, "Save the merged layout")
	var reload := saves.load_game()
	_check(reload.status == SaveService.Status.OK and reload.simulation.to_dict() == restored.to_dict(),
		"The merged layout must round-trip without relocating workers again")
	for tick in range(10):
		restored.step_simulation()
	_check(migrated.owner_of(3) != miner.id and migrated.validate().is_empty(),
		"The migrated miner must finish unloading without losing any stone")
