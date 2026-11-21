extends RefCounted

const SaveService = preload("res://scripts/application/save_service.gd")
const Blueprint = preload("res://scripts/domain/blueprint.gd")
const PanelSettings = preload("res://scripts/application/panel_settings.gd")
const Simulation = preload("res://scripts/simulation/simulation_runner.gd")
const QuarryProduction = preload("res://scripts/simulation/quarry_production.gd")
const Wallpaper = preload("res://scripts/application/wallpaper.gd")
const State = preload("res://scripts/domain/game_state.gd")

const MIXED := [
	{"x": 0, "y": 0, "type": "stone", "size": 4},
	{"x": 4, "y": 0, "type": "stone", "size": 2},
	{"x": 6, "y": 0, "type": "stone", "size": 1},
	{"x": 6, "y": 1, "type": "stone", "size": 1},
	{"x": 4, "y": 2, "type": "stone", "size": 2},
	{"x": 0, "y": 4, "type": "stone", "size": 4},
]

var _failed := false


func _check(condition: bool, message := "Mixed blueprint assertion failed") -> void:
	if not condition:
		_failed = true
		push_error(message)


func run() -> bool:
	_failed = false
	_check_blueprint_validation()
	_check_settings_compatibility()
	_check_storage_layout()
	_check_raw_delivery_return()
	_check_delivery_ahead_of_placement()
	_check_quarry_cuts()
	_check_quarry_migration()
	if not _check_mixed_simulation() or _failed:
		return false
	print("PASS: mixed 1x1/2x2/4x4 blueprint, production, transport and resume")
	return true


func _check_blueprint_validation() -> void:
	var legacy := Blueprint.validate({"version": 1, "blocks": [{"x": 2, "y": 0, "type": "stone"}]})
	_check(not legacy.has("error") and legacy.version == 1 and legacy.blocks[0].size == 1)
	var checked := Blueprint.validate({"version": 2, "blocks": MIXED})
	_check(not checked.has("error") and checked.blocks.size() == 6)
	_check(Blueprint.validate({"version": 2, "blocks": [{"x": 174, "y": 86, "size": 4, "type": "stone"}]}).has("error"))
	_check(Blueprint.validate({"version": 2, "blocks": [{"x": 173, "y": 87, "size": 4, "type": "stone"}]}).has("error"))
	_check(Blueprint.validate({"version": 2, "blocks": [
		{"x": 0, "y": 0, "size": 4, "type": "stone"},
		{"x": 3, "y": 3, "size": 1, "type": "stone"},
	]}).has("error"))
	_check(not Blueprint.validate({"version": 2, "blocks": [
		{"x": 0, "y": 0, "size": 1, "type": "stone"},
		{"x": 0, "y": 1, "size": 2, "type": "stone"},
	]}).has("error"))
	_check(not Blueprint.validate({"version": 2, "blocks": [
		{"x": 173, "y": 86, "size": 4, "type": "stone"},
	]}).has("error"))


func _check_settings_compatibility() -> void:
	var old_settings := {
		"version": 1, "minerMove": 2.6, "mineSeconds": 3.5, "porterEmpty": 3.2,
		"porterLoaded": 2.8, "loadSeconds": 0.5, "unloadSeconds": 0.7,
		"dressSeconds": 3.0, "dresserMove": 3.2, "builderMove": 3.2,
		"placeSeconds": 2.4, "liftBase": 1.5, "liftPerRow": 0.15,
		"rebuildSeconds": 1.0, "porterCount": 2, "minerCount": 2,
		"dresserCount": 2, "builderCount": 2, "weatherMin": 100,
		"weatherMax": 200, "weatherTransition": 24, "clearWeight": 1,
		"partlyWeight": 1, "cloudyWeight": 1,
	}
	var checked := PanelSettings.validate(old_settings)
	_check(checked.sizePenalty == 1.5)
	var balance: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	PanelSettings.apply(balance, checked)
	_check(balance.world.sizePenalty == 1.5)


func _check_storage_layout() -> void:
	var checked := Blueprint.validate({"version": 2, "blocks": MIXED})
	var balance: Dictionary = Wallpaper.wallpaper_balance(JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json")))
	balance.world["blueprintBlocks"] = checked.blocks
	balance.world.pyramidRows = 4
	balance.workers.porter.count = 3
	var state := State.new(balance)
	var bounds := state.geometry.raw_storage_bounds()
	var large := state._find_raw_place(0, {})
	_check(is_finite(large))
	_check(large - state.geometry.raw_block_width(0) * 0.5 >= bounds.x)
	_check(large + state.geometry.raw_block_width(0) * 0.5 <= bounds.y)
	var first := state._find_raw_place(2, {})
	var places: Dictionary[int, float] = {2: first}
	var second := state._find_raw_place(3, places)
	_check(second - first >= state.geometry.raw_block_width(2) + State.RAW_GAP)
	places[3] = second
	_check(not is_finite(state._find_raw_place(0, places)))
	places.erase(2)
	_check(is_equal_approx(state._find_raw_place(2, places), first))
	for resource_id in range(3):
		_check(state.reserve_transfer(State.Owner.MINER, [resource_id]))
		_check(state.deliver(State.Owner.MINER, resource_id))
	_check(state.reserve_transfer(10, [0]))
	_check(state.reserve_transfer(11, [1]))
	_check(not state.reserve_transfer(12, [2]))
	_check(state._raw_places.size() == 2 and state.validate().is_empty())
	_check(state.cancel_transfer(10))
	_check(state.reserve_transfer(12, [2]))
	_check(is_equal_approx(state.raw_place(2).x, first))
	_check(state.pick_up(12, 2) and state.deliver(12, 2))
	_check(state.reserve_transfer(State.Owner.DRESSER, [2], State.Owner.RAW))
	_check(state.pick_up(State.Owner.DRESSER, 2))
	_check(not state._raw_places.has(2))
	_check(state.deliver(State.Owner.DRESSER, 2) and state.validate().is_empty())
	var legacy := State.new(balance)
	for resource_id in range(3):
		legacy._move(resource_id, State.Owner.UNMINED, State.Owner.RAW)
	_check(legacy._restore_raw_places({}))
	_check(legacy._raw_places.size() < legacy.stock_count(State.Owner.RAW))
	_check(legacy.validate().is_empty())


func _check_raw_delivery_return() -> void:
	var checked := Blueprint.validate({"version": 2, "blocks": MIXED})
	var balance: Dictionary = Wallpaper.wallpaper_balance(JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json")))
	balance.world["blueprintBlocks"] = checked.blocks
	balance.world.pyramidRows = 4
	var state := State.new(balance)
	for resource_id in [0, 1]:
		_check(state.reserve_transfer(State.Owner.MINER, [resource_id]))
		_check(state.deliver(State.Owner.MINER, resource_id))
	var production := QuarryProduction.new(state, balance.workers)
	var porter := state.worker(State.Owner.FIRST_PORTER)
	production._assign_porter(porter.id)
	var batch := state.task_resource_ids(porter.id)
	_check(batch.size() == 2, "Raw haul reserves two different sizes")
	if batch.size() != 2:
		return
	_check(state.reserve_transfer(State.Owner.MINER, [2]))
	production.apply_completion({"worker_id": State.Owner.MINER, "state": &"mine"})
	var phases: Array = porter.timing_snapshot().phases
	var approaches := phases.filter(func(phase: Dictionary) -> bool: return phase.state == &"walk_to_storage")
	_check(approaches.size() == 2, "Raw haul walks to both reserved slots")
	if approaches.size() != 2:
		return
	var raw := state.geometry.raw_storage()
	var junction := [raw.x, raw.y]
	_check(approaches[0].route[-2] == junction, "Loaded approach reaches the junction before the slot")
	_check(state.raw_place(batch[-1]).x < state.raw_place(batch[0]).x,
		"The last block loaded is reserved the first available slot")
	for index in range(2):
		var slot := state.raw_place(batch[1 - index])
		_check(approaches[index].route[-1] == [slot.x, slot.y], "Walk ends at the slot of the next block off the sled")
	_check(phases[-1].state == &"return_to_raw_storage" and phases[-1].route[-1] == junction)
	for tick in range(1000):
		for event in porter.advance(0.1):
			production.apply_completion(event)
		if porter.fsm_state == &"idle":
			break
	batch.reverse()
	_check(state.stock(State.Owner.RAW) == batch and porter.position == raw,
		"Both blocks are delivered in unloading order and the porter returns")


func _check_delivery_ahead_of_placement() -> void:
	var checked := Blueprint.validate({"version": 2, "blocks": MIXED})
	var balance: Dictionary = Wallpaper.wallpaper_balance(JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json")))
	balance.world["blueprintBlocks"] = checked.blocks
	balance.world.pyramidRows = 4
	balance.workers.porter.capacity = 1
	var state := State.new(balance)
	state._move(0, State.Owner.UNMINED, State.Owner.FINISHED)
	state._move(1, State.Owner.UNMINED, State.Owner.QUARRY)
	state._move(2, State.Owner.UNMINED, State.Owner.QUARRY)
	_check(state.placed_count() == 0 and state.validate().is_empty())
	var production := QuarryProduction.new(state, balance.workers)
	production.assign_tasks()
	_check(state.task_resource_ids(State.Owner.FIRST_PORTER) == [1],
		"Porter must deliver the next stone while the builder has not placed block 0")
	var porter := state.worker(State.Owner.FIRST_PORTER)
	for tick in range(2000):
		for event in porter.advance(0.1):
			production.apply_completion(event)
		if state.owner_of(1) == State.Owner.RAW:
			break
	_check(state.owner_of(1) == State.Owner.RAW and state.placed_count() == 0
		and state.validate().is_empty(), "Next stone must reach the mason before placement")


func _check_quarry_cuts() -> void:
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	var balance := Wallpaper.wallpaper_balance(base)
	balance.world["blueprintBlocks"] = Blueprint.validate({"version": 2, "blocks": MIXED}).blocks
	var geometry := State.new(balance).geometry
	var excavation := geometry.quarry_excavation
	var unit := geometry.brick_size() * State.Geometry.LIMESTONE_SCALE
	_check(excavation.outline(0).is_empty() and excavation.scaffold_paths(0).is_empty(), "Intact sand needs no scaffold")
	for id in range(MIXED.size()):
		var cut := excavation.cut(id)
		var center := cut.get_center().x
		_check(cut.size.is_equal_approx(unit * MIXED[id].size), "Cut matches the raw block dimensions")
		excavation.outline(id)
		_check(is_equal_approx(excavation.terrain_y(center), cut.end.y), "Next stone is exposed from above")
		var paths := excavation.scaffold_paths(id + 1)
		_check(is_equal_approx(excavation.terrain_y(center), cut.position.y), "Extraction removes one block depth")
		var pickup := geometry.quarry_pickup(id, id + 1)
		var work := geometry.miner_work_position(id, id)
		_check(pickup.y == cut.position.y and is_equal_approx(work.y, cut.end.y),
			"The miner strikes the exposed face and the porter loads from the cut floor")
		var shaft := paths[0]
		var haul := geometry.quarry_to_raw(id, id + 1)
		var landing := -1
		for level in range(shaft.size()):
			if shaft[level].y == pickup.y:
				landing = level
				break
		_check(landing > 0 and haul[0] == pickup and haul[-1] == geometry.raw_storage(),
			"The loaded haul reaches the warehouse from a landing on the shared staircase")
		for level in range(landing + 1):
			_check(haul.has(shaft[level]), "The loaded haul uses the same staircase at every level")


func _check_quarry_migration() -> void:
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	var balance := Wallpaper.wallpaper_balance(base)
	balance.world["blueprintBlocks"] = Blueprint.validate({"version": 2, "blocks": MIXED}).blocks
	var legacy_balance := balance.duplicate(true)
	legacy_balance.world.erase("quarryBlockCuts")
	var legacy := Simulation.for_wallpaper(legacy_balance) as Simulation
	var path := "user://quarry-test/legacy.json"
	var old_save := SaveService.new(legacy_balance, path)
	var new_save := SaveService.new(balance, path)
	var checked := {}
	var porter := State.Owner.FIRST_PORTER
	for tick in range(3000):
		legacy.step_simulation()
		var before := legacy.state.worker(porter)
		if legacy.state.transfer_source(porter) != State.Owner.QUARRY or checked.has(before.fsm_state):
			continue
		checked[before.fsm_state] = true
		_check(old_save.save_game(legacy) == OK, "Write a slope quarry snapshot")
		var loaded := new_save.load_game()
		_check(loaded.status == SaveService.Status.OK, "Read the slope snapshot on the cut layout")
		if loaded.status != SaveService.Status.OK:
			continue
		var restored: Simulation = loaded.simulation
		var after := restored.state.worker(porter)
		_check(before.fsm_state == after.fsm_state and before.remaining_work == after.remaining_work
			and legacy.state.to_dict() == restored.state.to_dict(), "Migration preserves work and ownership")
		if after.fsm_state == &"load":
			var id := restored.state.pickup_targets(porter)[0]
			_check(after.position == restored.state.geometry.quarry_pickup(id, restored.state.mined_count()),
				"Resumed loading is at the reserved stone")
		for step in range(3000):
			restored.step_simulation()
			if restored.state.finished:
				break
		_check(restored.state.finished and restored.state.validate().is_empty(), "The migrated blueprint finishes")
		if checked.size() == 4:
			break
	_check(checked.size() == 4, "Migrate approach, loading, exit and unloading")
	for suffix in ["", ".bak"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path + suffix))


func _check_mixed_simulation() -> bool:
	var checked := Blueprint.validate({"version": 2, "blocks": MIXED})
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	var balance := Wallpaper.wallpaper_balance(base)
	balance.world["blueprintBlocks"] = checked.blocks
	balance.world.pyramidRows = 4
	balance.world.sizePenalty = 1.5
	for role in ["miner", "dresser", "builder", "porter"]:
		balance.workers[role].count = 2
	for storage in balance.storages:
		if storage != 'platform':
			balance.storages[storage] = 2
	var sim := Simulation.for_wallpaper(balance)
	var geometry = sim.state.geometry
	_check(geometry.row_count() == 4 and sim.state.target_count() == 6)
	_check(geometry.stage_height(3) == geometry.brick_size().y * 4.0)
	_check(geometry.block_multiplier(0) == 6.0 and geometry.block_multiplier(1) == 3.0)
	_check(geometry.block_multiplier(2) == 1.0 and geometry.block_multiplier(5) == 6.0)
	var production := QuarryProduction.new(sim.state, balance.workers)
	_check(is_equal_approx(production._loaded_speed([0]), balance.workers.porter.loadedSpeed / 6.0))
	_check(is_equal_approx(production._loaded_speed([1]), balance.workers.porter.loadedSpeed / 3.0))
	_check(is_equal_approx(production._loaded_speed([2]), balance.workers.porter.loadedSpeed))

	var saw_large_mine := false
	var saw_entry_return := false
	var last_placed := 0
	var last_progress_tick := 0
	for tick in range(500000):
		var active_builder = sim.state.worker(sim.state.active_builder_id)
		if active_builder.fsm_state == &"walk_to_brick" and sim.state.placed_count() < sim.state.target_count():
			var work_route: PackedVector2Array = active_builder.movement_route()
			var target: Dictionary = geometry.block_for_placement(sim.state.placed_count())
			var tip: Vector2 = sim.state.scaffold_paths[-1][-1]
			var unit: Vector2 = geometry.brick_size()
			_check(not work_route.is_empty() and work_route[-1] == tip
				and is_equal_approx(tip.y, (floorf(float(target.y) / 2.0) * 2.0 + 2.0) * unit.y),
				"Builder works at the growing end of the scaffold")
		if active_builder.fsm_state == &"walk_to_workshop" and sim.state.current_row > 0:
			var route: PackedVector2Array = active_builder.movement_route()
			if route.has(sim.state.scaffold_paths[0][0]):
				saw_entry_return = true
		var events: Array[Dictionary] = sim.step_simulation()
		for id in sim.state.worker_ids_for_role(State.Worker.Role.MINER):
			var miner = sim.state.worker(id)
			if miner.fsm_state == &"mine" and not saw_large_mine:
				_check(is_equal_approx(miner.phase_work(), balance.workers.miner.mineSeconds * 6.0))
				saw_large_mine = true
		for event in events:
			if event.state == &"place_brick":
				var index: int = event.placement_index
				var placed: Array = sim.state.stock(State.Owner.PLACED)
				_check(index == last_placed and placed[index] == index)
				_check(geometry.block_size_for_resource(placed[index]) == int(checked.blocks[index].size))
				var block: Dictionary = geometry.block_for_placement(index)
				_check(block.x == checked.blocks[index].x and block.y == checked.blocks[index].y)
				last_placed += 1
				last_progress_tick = tick
		if tick - last_progress_tick > 20000:
			var builder = sim.state.worker(sim.state.active_builder_id)
			push_error("Mixed blueprint stalled after block %d at tick %d: row=%d phase=%s pos=%s scaffolds=%d delivery=%s work=%s stocks=%s" % [
				last_placed, tick, sim.state.current_row, builder.fsm_state,
				str(builder.position), sim.state.scaffold_paths.size(),
				str(sim.state.delivery_point), str(sim._construction._placement_point()),
				str([sim.state.stock_count(State.Owner.WORKSHOP_OUTPUT), sim.state.stock_count(State.Owner.FINISHED),
					sim.state.stock_count(State.Owner.PLATFORM), sim.state.owner_of(last_placed)])])
			return false
		if tick % 25 == 24:
			_check(sim.state.validate().is_empty())
			var resumed = Simulation.from_dict(balance, JSON.parse_string(JSON.stringify(sim.to_dict())))
			_check(resumed != null)
			_check_snapshot_round_trip(sim, resumed, tick)
			sim = resumed
		if sim.state.finished:
			break
	if not (saw_large_mine and saw_entry_return and sim.state.finished
			and last_placed == checked.blocks.size()):
		push_error("Mixed blueprint did not finish: placed=%d, row=%d, builder=%s" % [
			last_placed, sim.state.current_row,
			sim.state.worker(sim.state.active_builder_id).fsm_state])
		return false
	_check(sim.state.validate().is_empty())
	return true


func _check_snapshot_round_trip(sim: Simulation, resumed: Simulation, tick: int) -> void:
	var before := sim.to_dict()
	var after := resumed.to_dict()
	if before != after:
		var builder := sim.state.worker(sim.state.active_builder_id)
		var restored := resumed.state.worker(builder.id)
		var old_route := builder.movement_route()
		var new_route := restored.movement_route()
		# Construction can replan an invalid scaffold segment from the saved position.
		# Transfers, reserves and every other worker still have to round-trip exactly.
		if builder.fsm_state == &"return_to_platform" and not old_route.is_empty() \
				and not new_route.is_empty() and new_route[0] == builder.position \
				and old_route[-1] == new_route[-1] \
				and not resumed._construction._active_route_valid(builder, old_route):
			for index in range(before.workers.size()):
				var saved: Dictionary = before.workers[index]
				if saved.id == builder.id:
					var replanned: Dictionary = after.workers[index]
					saved.path_segment = replanned.path_segment
					saved.remaining_distance = replanned.remaining_distance
					saved.phases[0].route = replanned.phases[0].route
					break
	_check(before == after, "Snapshot differs at tick %d" % tick)
