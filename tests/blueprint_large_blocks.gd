extends RefCounted

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
	if not _check_mixed_simulation() or _failed:
		return false
	print("PASS: mixed 1x1/2x2/4x4 blueprint, production, transport and resume")
	return true


func _check_blueprint_validation() -> void:
	var legacy := Blueprint.validate({"version": 1, "blocks": [{"x": 2, "y": 0, "type": "stone"}]})
	_check(not legacy.has("error") and legacy.version == 1 and legacy.blocks[0].size == 1)
	var checked := Blueprint.validate({"version": 2, "blocks": MIXED})
	_check(not checked.has("error") and checked.blocks.size() == 6)
	_check(Blueprint.validate({"version": 2, "blocks": [{"x": 56, "y": 0, "size": 4, "type": "stone"}]}).has("error"))
	_check(Blueprint.validate({"version": 2, "blocks": [
		{"x": 0, "y": 0, "size": 4, "type": "stone"},
		{"x": 3, "y": 3, "size": 1, "type": "stone"},
	]}).has("error"))
	_check(not Blueprint.validate({"version": 2, "blocks": [
		{"x": 0, "y": 0, "size": 1, "type": "stone"},
		{"x": 0, "y": 1, "size": 2, "type": "stone"},
	]}).has("error"))
	_check(not Blueprint.validate({"version": 2, "blocks": [
		{"x": 55, "y": 0, "size": 4, "type": "stone"},
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
	for staged in [false, true]:
		var state := State.new(balance)
		_check(state.reserve_transfer(State.Owner.MINER, [0]))
		_check(state.deliver(State.Owner.MINER, 0))
		if staged:
			_check(state.reserve_transfer(State.Owner.MINER, [0], State.Owner.QUARRY))
			_check(state.pick_up(State.Owner.MINER, 0))
			_check(state.deliver(State.Owner.MINER, 0))
		var production := QuarryProduction.new(state, balance.workers)
		production.assign_tasks()
		var phases: Array = state.worker(State.Owner.FIRST_PORTER).timing_snapshot().phases
		_check(not phases.is_empty() and phases[-1].state == &"return_to_raw_storage")


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
			_check(not work_route.is_empty() and is_equal_approx(work_route[-1].y,
				float(target.y) * geometry.brick_size().y), "Work point must use target lower face")
		if active_builder.fsm_state == &"walk_to_workshop" and sim.state.current_row > 0:
			var return_route: PackedVector2Array = active_builder.movement_route()
			var entry := Vector2(float(balance.world.pyramidLeft) - 2.0 * geometry.brick_size().x, 0.0)
			if return_route.has(entry):
				saw_entry_return = true
				var placed_geometry: Dictionary = sim.state.placed_surface_snapshot()
				for segment in range(1, return_route.size()):
					_check(geometry._scaffold_clear_segment(placed_geometry,
						return_route[segment - 1], return_route[segment],
						0.18 * geometry.brick_size().x, 0.9 * geometry.brick_size().y,
						0.02 * geometry.brick_size().y), "Workshop return crosses masonry")
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
			push_error("Mixed blueprint stalled after block %d at tick %d: row=%d phase=%s pos=%s waiting=%s scaffolds=%d delivery=%s work=%s stocks=%s" % [
				last_placed, tick, sim.state.current_row, builder.fsm_state,
				str(builder.position), str(sim._construction.waiting_snapshot()), sim._construction._scaffolds.size(),
				str(sim.state.delivery_point), str(sim._construction._placement_point()),
				str([sim.state.stock_count(State.Owner.WORKSHOP_OUTPUT), sim.state.stock_count(State.Owner.FINISHED),
					sim.state.stock_count(State.Owner.PLATFORM), sim.state.owner_of(last_placed)])])
			return false
		if tick % 25 == 24:
			_check(sim.state.validate().is_empty())
			var resumed = Simulation.from_dict(balance, JSON.parse_string(JSON.stringify(sim.to_dict())))
			_check(resumed != null)
			_check(sim.to_dict() == resumed.to_dict())
			sim = resumed
		if sim.state.finished:
			break
	if not (saw_large_mine and saw_entry_return and sim.state.finished
			and last_placed == checked.blocks.size()):
		push_error("Mixed blueprint did not finish: placed=%d, row=%d, builder=%s, waiting=%s" % [
			last_placed, sim.state.current_row,
			sim.state.worker(sim.state.active_builder_id).fsm_state,
			str(sim._construction.waiting_snapshot())])
		return false
	_check(sim.state.validate().is_empty())
	return true
