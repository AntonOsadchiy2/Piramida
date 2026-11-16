extends SceneTree

const Geometry = preload("res://scripts/domain/world_geometry.gd")

const State = preload("res://scripts/domain/game_state.gd")
const Simulation = preload("res://scripts/simulation/simulation_runner.gd")
const Quarry = preload("res://scripts/simulation/quarry_production.gd")
const PurchaseCommands = preload("res://scripts/application/purchase_commands.gd")
const SaveService = preload("res://scripts/application/save_service.gd")
const Lifecycle = preload("res://scripts/application/lifecycle_controller.gd")
const GameSession = preload("res://scripts/application/game_session.gd")
const Owner = State.Owner

var failures: Array[String] = []


func _initialize() -> void:
	check_balance()
	check_main_scene()

	for failure in failures:
		printerr(failure)

	if failures.is_empty():
		print("Foundation, geometry, resource, simulation and full production checks passed.")
		quit(0)
	else:
		quit(1)


func check_balance() -> void:
	var file := FileAccess.open("res://data/balance.json", FileAccess.READ)
	if file == null:
		failures.append("Cannot open balance.json: %s" % error_string(FileAccess.get_open_error()))
		return

	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK:
		failures.append("balance.json:%d: %s" % [parser.get_error_line(), parser.get_error_message()])
		return

	if not parser.data is Dictionary:
		failures.append("balance.json must contain a JSON object.")
		return

	var balance: Dictionary = parser.data
	for section in ["world", "storages", "workers", "lift", "economy", "upgrades", "simulation"]:
		if not balance.get(section) is Dictionary:
			failures.append("Missing or invalid balance section: %s" % section)


	if failures.is_empty():
		check_geometry(Geometry.new(balance))
		check_resources(balance)
		check_simulation(balance)
		check_purchase_limits(balance)
		check_purchase_effects(balance)
		check_purchases_during_production(balance)
		check_quarry_production(balance)
		check_miner_clears_quarry(balance)
		check_porter_batches(balance)
		check_porter_load_speed(balance)
		check_builder_workshop_pickup(balance)
		check_lift_assistance(balance)
		check_miner_stays_at_lift(balance)
		check_full_production(balance, false)
		check_full_production(balance, true)
		check_full_production(balance, false, 8, State.MAX_PORTER_CAPACITY)
		check_saves(balance)
		check_lifecycle(balance)


func check_simulation(balance: Dictionary) -> void:
	var first_run: Array = []
	for run in range(2):
		var sim := Simulation.new(balance, false)
		var miner := sim.state.worker(Owner.MINER)
		var dresser := sim.state.worker(Owner.DRESSER)
		miner.position = Vector2.ZERO
		var route := PackedVector2Array([
			Vector2.ZERO, Vector2(0.125, 0), Vector2(0.125, 0), Vector2(0.125, 0.125),
		])
		if not miner.queue_work(&"prepare", 0.05, 1.0) \
				or not miner.queue_move(&"walk", route, 1.0) \
				or not miner.queue_work(&"finish", 0.025, 1.0) \
				or not dresser.queue_work(&"process", 0.4, 1.0):
			failures.append("Could not schedule simulation fixtures.")
			return

		var first := sim.step_simulation()
		var saved := sim.timing_snapshot()
		if first.size() != 1 or first[0].state != &"prepare" \
				or not miner.position.is_equal_approx(Vector2(0.05, 0)) \
				or not is_equal_approx(miner.remaining_distance, 0.075) \
				or not is_equal_approx(dresser.remaining_work, 0.3):
			failures.append("A tick must spend its remainder on movement and advance other workers once.")
		if not miner.set_active_rate(2.0) or not dresser.set_active_rate(3.0) \
				or not miner.position.is_equal_approx(Vector2(0.05, 0)) \
				or not is_equal_approx(dresser.remaining_work, 0.3):
			failures.append("A rate change must preserve position and remaining work.")

		var second := sim.step_simulation()
		if second.size() != 2 or second[0].state != &"walk" or second[1].state != &"process" \
				or miner.position != route[-1] or not is_equal_approx(miner.remaining_work, 0.025):
			failures.append("Compound route timing or simultaneous completion order is incorrect.")
		if not dresser.queue_move(&"stationary", PackedVector2Array([dresser.position]), 1.0) \
				or not dresser.queue_work(&"instant", 0.0, 1.0) \
				or not dresser.queue_work(&"next", 0.2, 1.0):
			failures.append("Could not assign phases at a tick boundary.")
		if dresser.remaining_work != 0.0:
			failures.append("New assignments received time before the next tick.")
		var third := sim.step_simulation()
		if third.size() != 3 or third[0].state != &"finish" or third[1].state != &"stationary" \
				or third[2].state != &"instant" or not is_equal_approx(dresser.remaining_work, 0.1) \
				or not is_equal_approx(sim.elapsed_seconds(), 0.3):
			failures.append("Zero-time phases must finish once and preserve the tick budget.")
		var decoded: Variant = JSON.parse_string(JSON.stringify(saved))
		if saved.tick != 1 or not is_equal_approx(saved.workers[0].remaining_distance, 0.075) \
				or not decoded is Dictionary or decoded.tick != 1 \
				or decoded.workers[0].phases[0].route[3] != [0.125, 0.125]:
			failures.append("Timing snapshot must be detached and JSON compatible.")
		var trace := [first, second, third, saved, sim.timing_snapshot()]
		if run == 0:
			first_run = trace
		elif trace != first_run:
			failures.append("Repeated simulation produced different events or timing state.")


func check_main_scene() -> void:
	var scene_path: String = ProjectSettings.get_setting("application/run/main_scene", "")
	if scene_path.is_empty():
		failures.append("The main scene is not configured.")
		return

	var scene := load(scene_path) as PackedScene
	if scene == null:
		failures.append("Cannot load the main scene: %s" % scene_path)
		return

	var main := scene.instantiate()
	var expected_classes := {
		".": "Node2D",
		"World": "Node2D",
		"World/PyramidTiles": "TileMapLayer",
		"World/Workers": "Node2D",
		"World/Cargo": "Node2D",
		"World/Camera2D": "Camera2D",
		"HUD": "CanvasLayer",
		"HUD/Control": "Control",
		"Audio": "Node",
	}
	for path in expected_classes:
		var node := main.get_node_or_null(path)
		if node == null or node.get_class() != expected_classes[path]:
			failures.append("Expected %s at %s." % [expected_classes[path], path])
	main.free()


func expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func check_geometry(world: Geometry) -> void:
	expect(world.quarry_count() == 900, "Quarry must contain 900 cells.")
	expect(world.quarry_cell(-1) == null and world.quarry_cell(900) == null,
		"Invalid IDs must have no cell.")
	expect(world.miner_to_next_cell(899).is_empty(), "Mining must stop at exhaustion.")
	var first := [Vector2i.ZERO, Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]
	for id in range(first.size()):
		expect(world.quarry_grid_cell(id) == first[id], "Three top cells and one below the middle.")
	var unique := {}
	var row_widths := PackedInt32Array()
	row_widths.resize(world.quarry_layers())
	for id in range(world.quarry_count()):
		var cell := world.quarry_grid_cell(id)
		expect(not unique.has(cell), "Each quarry cell must be unique.")
		if cell.y > 0:
			expect(unique.has(cell - Vector2i.DOWN), "The cell above must be open first.")
		unique[cell] = true
		row_widths[cell.y] += 1
		var route := world.quarry_to_raw(id, id + 1)
		expect(route[0] == world.quarry_pickup(id) and route[-2] == world.quarry_edge(0, 1, id + 1)
			and route[-1] == world.raw_storage(),
			"Hauling proceeds directly from the quarry entrance to raw stock.")
		for layer in range(cell.y + 2):
			expect(route[-2 - layer] == world.quarry_edge(layer, 1, id + 1),
				"Hauling follows the right quarry edge on floor %d." % layer)
		if id + 1 < world.quarry_count():
			var next := world.miner_to_next_cell(id)
			expect(next[0] == world.quarry_cell(id) and next[-1] == world.quarry_cell(id + 1),
				"Miner route endpoints for %d." % id)
	for layer in range(row_widths.size()):
		expect(row_widths[layer] == 59 - 2 * layer, "Quarry narrows toward the bottom.")
	expect(world.quarry_depth(3) == 0 and world.quarry_depth(4) == 1
		and world.quarry_depth(9) == 2 and world.quarry_depth(900) == 29, "Opening depths track mining order.")

	var total := 0
	for row in range(30):
		var count := world.row_size(row)
		total += count
		expect(count == 59 - 2 * row, "Brick count in row %d." % row)
		expect(world.brick_origin(row, -1) == null and world.brick_origin(row, count) == null,
			"Column bounds in row %d." % row)
		var lift := world.lift_route(row)
		if row == 0:
			expect(lift.is_empty() and world.lift_seconds(row) == 0.0
				and world.finished_storage() == world.platform(row), "Ground row picks up at the lift base.")
		else:
			expect(lift[0] == world.finished_storage() and lift[-1] == world.platform(row),
				"Lift endpoints for row %d." % row)
			expect(is_equal_approx(Geometry.route_length(lift), row * 0.64),
				"Lift distance for row %d." % row)
			expect(is_equal_approx(world.lift_seconds(row), 1.5 + row * 0.15),
				"Lift duration for row %d." % row)
		for column in range(count):
			var brick: Vector2 = world.brick_origin(row, column)
			expect(brick.is_equal_approx(Vector2(9.0 + (row + column) * 0.36, row * 0.28)),
				"Brick origin for row %d column %d." % [row, column])
			var walk := world.builder_to_brick(row, column)
			var rise := 0.0 if row == 0 else 0.28
			expect(walk[0] == world.platform(row)
				and walk[-1].is_equal_approx(brick + Vector2(0.18, rise)),
				"Builder route endpoints for row %d column %d." % [row, column])
			expect(is_equal_approx(Geometry.route_length(walk), 0.98 + column * 0.36 + rise),
				"Builder route length for row %d column %d." % [row, column])
		if row < 29:
			var transfer := world.platform_to_next_row(row)
			expect(transfer[0] == world.platform(row) and transfer[-1] == world.platform(row + 1)
				and is_equal_approx(Geometry.route_length(transfer), 0.64), "Platform transition.")

	expect(total == 900, "Pyramid must contain 900 cells.")
	expect(world.platform(-1) == null and world.platform(30) == null,
		"Invalid rows must have no platform.")
	expect(world.platform_to_next_row(29).is_empty(), "No transition beyond the final row.")
	expect(is_equal_approx(world.rebuild_seconds(), 1.0), "Scaffold rebuild duration.")


func check_resources(balance: Dictionary) -> void:
	var config := balance.duplicate(true)
	config.workers.porter.count = 2
	config.storages.quarryReadyCapacity = 3
	config.storages.raw = 2
	config.storages.finished = 1
	config.storages.workshopOutput = 1
	var state := State.new(config)
	var porter: int = Owner.FIRST_PORTER
	var other_porter := porter + 1
	state.porter_capacity = 2

	resource_expect(state.stock_count(Owner.UNMINED) == 900, "Initial resource count")
	resource_expect(state.resource_record(899).source_layer == 29, "Permanent quarry coordinates")
	resource_expect(state.worker_ids().size() == 6, "Configured workers")
	resource_expect(not state.reserve_transfer(Owner.MINER, [1]), "Reject skipping a quarry cell")
	for id in range(3):
		resource_expect(state.reserve_transfer(Owner.MINER, [id]), "Reserve next stone")
		resource_expect(state.deliver(Owner.MINER, id), "Move mined stone to the queue")
	resource_expect(not state.reserve_transfer(porter, [0, 0]), "Reject duplicates within a batch")
	resource_expect(not state.reserve_transfer(porter, [0, 999]), "Reject invalid IDs")
	resource_expect(state.incoming_count(Owner.RAW) == 0, "Rejected batch leaves no reservations")

	resource_expect(state.reserve_transfer(porter, [0]), "Reserve first porter job")
	resource_expect(not state.reserve_transfer(other_porter, [0]), "Reject double claim with room at destination")
	resource_expect(state.reserve_transfer(other_porter, [1]), "Reserve independent porter job")
	resource_expect(state.stock_count(Owner.QUARRY) == 3, "Reserved stones still occupy quarry slots")
	resource_expect(not state.reserve_transfer(Owner.MINER, [3]), "Claims do not free space for mining")
	resource_expect(state.cancel_transfer(porter), "Cancel uncollected job")
	resource_expect(state.reserved_by(0) == -1 and state.incoming_count(Owner.RAW) == 1, "Cancel releases claim and slot")
	resource_expect(not state.reserve_transfer(porter, [0, 2]), "Reject batch exceeding remaining space")
	resource_expect(state.reserved_by(0) == -1 and state.reserved_by(2) == -1, "Batch rejection is atomic")
	resource_expect(state.reserve_transfer(porter, [0]), "Reuse released claim and slot")
	resource_expect(not state.deliver(porter, 0), "Reject delivery before pickup")
	resource_expect(not state.pick_up(other_porter, 0), "Reject picking up another worker's claim")
	resource_expect(state.pick_up(porter, 0), "Transfer stone to porter")
	resource_expect(not state.cancel_transfer(porter), "Reject cancellation with cargo")
	resource_expect(state.validate().is_empty(), "Invariants with cargo and queued claims")
	resource_expect(state.deliver(porter, 0), "Convert reserved slot to physical stock")
	resource_expect(not state.deliver(porter, 0), "Reject repeated delivery")
	resource_expect(not state.reserve_transfer(porter, [2]), "Physical stock and incoming claims share capacity")
	resource_expect(state.cancel_transfer(other_porter), "Release second job")

	resource_expect(state.reserve_transfer(Owner.DRESSER, [0]), "Reserve workshop output")
	resource_expect(state.pick_up(Owner.DRESSER, 0) and state.deliver(Owner.DRESSER, 0), "Process stone without changing ID")
	resource_expect(state.reserve_transfer(porter, [1, 2]), "Reserve two-stone batch")
	resource_expect(state.pick_up(porter, 1) and state.deliver(porter, 1), "Deliver first item")
	resource_expect(state.task_resource_ids(porter) == [2], "Partial delivery keeps remaining reservation")
	resource_expect(not state.reserve_transfer(Owner.DRESSER, [1]), "Full output blocks processing")
	resource_expect(state.pick_up(porter, 2) and state.deliver(porter, 2), "Deliver remaining item")
	resource_expect(state.reserve_transfer(porter, [0], Owner.WORKSHOP_OUTPUT), "Reserve drop at the lift base")
	resource_expect(state.pick_up(porter, 0) and state.deliver(porter, 0), "Porter delivers a brick")
	resource_expect(state.reserve_transfer(Owner.BUILDER, [0], Owner.FINISHED), "Reserve ground-level brick")
	resource_expect(state.pick_up(Owner.BUILDER, 0) and state.deliver(Owner.BUILDER, 0), "Place brick")
	resource_expect(state.placed_count() == 1 and state.stock(Owner.PLACED) == [0], "Placed brick retains original ID")
	resource_expect(state.mined_count() == 3 and state.validate().is_empty(), "Invariants after all transfer types")

	# Deliberately damage storage and claims to exercise the diagnostic.
	state._stocks[Owner.RAW].append(1)
	resource_expect(state.validate().size() >= 2, "Detect duplicate ownership and overflowing stock")
	state._stocks[Owner.RAW].pop_back()
	resource_expect(state.reserve_transfer(Owner.DRESSER, [1]), "Set up task diagnostic")
	state._tasks[Owner.DRESSER].pending[0] = 0
	resource_expect(not state.validate().is_empty(), "Detect task linked to a resource at the wrong owner")


func resource_expect(condition: bool, description: String) -> void:
	if not condition:
		failures.append("Resource model: " + description)


func check_quarry_production(balance: Dictionary) -> void:
	var blocked := balance.duplicate(true)
	blocked.storages.finished = 0
	var sim := Simulation.new(blocked)
	var state := sim.state
	state.worker(Owner.BUILDER).queue_work(&"test_block_builder", 10000.0, 1.0)
	var porter := state.worker(Owner.FIRST_PORTER)
	var loading := false
	var unloading := false
	for tick in range(10000):
		sim.step_simulation()
		if porter.fsm_state == &"load" and not loading:
			var pending := state.task_resource_ids(porter.id)
			expect(pending == [0], "First trip must reserve exactly the first stone.")
			expect(state.resource_record(0).owner == Owner.QUARRY, "Loading must retain the stone in the quarry.")
			expect(state.incoming_count(Owner.RAW) == 1, "The storage slot must already be reserved at loading.")
			loading = true
		if porter.fsm_state == &"unload" and not unloading:
			expect(state.stock(porter.id) == [0] and state.stock_count(Owner.RAW) == 0,
				"Unloading must retain the stone on the porter until completion.")
			expect(state.incoming_count(Owner.RAW) == 1, "Unloading must retain the storage reservation.")
			unloading = true
		if not state.validate().is_empty():
			expect(false, "Production invariant violated at tick %d: %s" % [tick, state.validate()])
			return
	expect(loading and unloading, "The porter must load and unload.")
	expect(state.stock_count(Owner.RAW) == 30 and state.stock_count(Owner.QUARRY) == 15,
		"With the dresser output blocked, production must fill both upstream buffers and stop.")
	var workshop_capacity := int(blocked.storages.workshopOutput)
	expect(state.mined_count() == 53 + workshop_capacity and state.stock_count(Owner.QUARRY_STOCK) == 8
		and state.stock_count(Owner.WORKSHOP_OUTPUT) == workshop_capacity
		and state.incoming_count(Owner.RAW) == 0
		and state.incoming_count(Owner.QUARRY) == 0 and porter.fsm_state == &"idle",
		"Blocked production must leave no cargo or reservations in flight.")

	# Use a large receiver and a faster miner to exercise the entire quarry
	# while keeping undelivered stones on the previous layer at the crossing.
	var fixture := blocked.duplicate(true)
	fixture.storages.quarryStockCapacity = 0
	fixture.storages.raw = State.RESOURCE_COUNT
	fixture.storages.quarryReadyCapacity = 150
	fixture.workers.miner.mineSeconds = 0.1
	fixture.workers.miner.moveSpeed = 3.0
	fixture.workers.porter.emptySpeed = 40.0
	fixture.workers.porter.loadedSpeed = 40.0
	sim = Simulation.new(fixture)
	state = sim.state
	state.worker(Owner.BUILDER).queue_work(&"test_block_builder", 10000.0, 1.0)
	var miner := state.worker(Owner.MINER)
	var reached_deeper_floor := false
	var old_stones_waiting := false
	var previous_depth := 0
	for tick in range(50000):
		sim.step_simulation()
		var depth := state.geometry.quarry_depth(state.mined_count())
		reached_deeper_floor = reached_deeper_floor or depth > previous_depth
		previous_depth = depth
		if depth > 0 and not old_stones_waiting:
			for resource_id: int in state.stock(Owner.QUARRY):
				if state.geometry.quarry_grid_cell(resource_id).y < depth:
					old_stones_waiting = true
					break
		if state.stock_count(Owner.RAW) + state.stock_count(Owner.WORKSHOP_OUTPUT) == State.RESOURCE_COUNT:
			break
	expect(reached_deeper_floor and old_stones_waiting,
		"The miner must reach deeper floors while older stones remain available.")
	expect(state.stock_count(Owner.RAW) + state.stock_count(Owner.WORKSHOP_OUTPUT) == State.RESOURCE_COUNT
		and state.validate().is_empty(),
		"Every stone, including stones from old layers, must reach storage exactly once.")
	for tick in range(10):
		sim.step_simulation()
	expect(state.mined_count() == State.RESOURCE_COUNT and miner.fsm_state == &"exhausted"
		and miner.position == state.geometry.quarry_cell(State.RESOURCE_COUNT - 1)
		and state.task_resource_ids(Owner.MINER).is_empty(),
		"The exhausted miner must stay at the last cell without a new task.")


func check_miner_clears_quarry(balance: Dictionary) -> void:
	var config := balance.duplicate(true)
	config.storages.quarryReadyCapacity = 1
	config.storages.quarryStockCapacity = 1
	config.storages.raw = 1
	var sim := Simulation.new(config, false)
	var state := sim.state
	state._move(0, Owner.UNMINED, Owner.RAW)
	state._move(1, Owner.UNMINED, Owner.QUARRY)
	state.worker(Owner.MINER).position = state.geometry.quarry_cell(1)
	var raw := state.geometry.raw_storage()
	state.worker(Owner.FIRST_PORTER).queue_move(&"return_to_raw_storage",
		[raw, raw + Vector2(16, 0), raw], float(config.workers.porter.emptySpeed))
	sim = Simulation.from_dict(config, sim.to_dict())
	state = sim.state
	var miner := state.worker(Owner.MINER)
	for tick in range(400):
		sim.step_simulation()
		if miner.fsm_state == &"walk_to_storage" and state.stock(Owner.MINER) == [1]:
			break
	expect(state.stock(Owner.MINER) == [1] and state.stock_count(Owner.QUARRY) == 0
		and state.incoming_count(Owner.QUARRY_STOCK) == 1,
		"Picking up a blocked quarry stone frees the slot and reserves the staging space.")
	var restored = Simulation.from_dict(config, sim.to_dict())
	if restored == null:
		expect(false, "Restore the miner carrying a stone out of the quarry.")
		return
	sim = restored
	state = sim.state
	for tick in range(400):
		sim.step_simulation()
		if state.resource_record(1).owner in [Owner.RAW, Owner.DRESSER]:
			break
	var owner: int = state.resource_record(1).owner
	expect(owner in [Owner.RAW, Owner.DRESSER] and state.validate().is_empty(),
		"Porter collects the same stone from staging and delivers it to raw storage.")


func check_porter_batches(balance: Dictionary) -> void:
	var config := balance.duplicate(true)
	config.workers.porter.count = 3
	config.workers.porter.capacity = 4
	config.workers.porter.emptySpeed = 2000.0
	config.workers.porter.loadedSpeed = 1000.0
	config.workers.porter.loadSeconds = 0.2
	config.storages.raw = 3
	var state := State.new(config)
	var quarry := Quarry.new(state, config.workers)
	var first: int = Owner.FIRST_PORTER
	for resource_id in range(2):
		state._move(resource_id, Owner.UNMINED, Owner.PLACED)
	for resource_id in range(2, 6):
		state._move(resource_id, Owner.UNMINED, Owner.QUARRY)
	var geometry := state.geometry
	var mined := state.mined_count()
	var by_distance := func(a: int, b: int) -> bool:
		var a_length := Geometry.route_length(geometry.quarry_to_raw(a, mined))
		var b_length := Geometry.route_length(geometry.quarry_to_raw(b, mined))
		return a < b if a_length == b_length else a_length < b_length
	var nearest: Array[int] = [2, 3, 4, 5]
	nearest.sort_custom(by_distance)
	nearest.pop_back()
	nearest.reverse()

	quarry.assign_tasks()
	expect(state.pickup_targets(first) == nearest
		and state.task_resource_ids(first + 1).is_empty()
		and state.free_slots(Owner.RAW) == 0,
		"Closest stones can span floors, with the farthest pickup first and no overbooking.")
	var approach := Geometry.route_length(geometry.quarry_to_raw(nearest[0], mined)) / float(config.workers.porter.emptySpeed)
	for event in state.worker(first).advance(approach + 0.21):
		quarry.apply_completion(event)
	expect(state.stock(first) == [nearest[0]] and state.pickup_targets(first) == nearest.slice(1)
		and state.stock_count(Owner.QUARRY) == 3 and state.incoming_count(Owner.RAW) == 3
		and state.validate().is_empty(),
		"Partial loading must preserve cargo, uncollected targets and destination reservations.")

	config.storages.raw = 2
	config.workers.porter.capacity = 1
	config.workers.porter.emptySpeed = 10000.0
	config.workers.porter.loadedSpeed = 10000.0
	config.workers.porter.loadSeconds = 0.0
	config.workers.porter.unloadSeconds = 0.0
	var sim := Simulation.new(config)
	state = sim.state
	state.cancel_transfer(Owner.MINER)
	for resource_id in range(2):
		state._move(resource_id, Owner.UNMINED, Owner.PLACED)
	for resource_id in [2, 3]:
		state._move(resource_id, Owner.UNMINED, Owner.QUARRY)
	sim.step_simulation()
	var pair: Array[int] = [2, 3]
	pair.sort_custom(by_distance)
	expect(state.pickup_targets(first) == [pair[0]] and state.pickup_targets(first + 1) == [pair[1]]
		and state.task_resource_ids(first + 2).is_empty(),
		"Two incomplete batches must start immediately, including a stone from an older layer.")
	var unloaders: Array[int] = []
	for event in sim.step_simulation():
		if event.state == &"unload":
			unloaders.append(event.worker_id)
	expect(unloaders == [first, first + 1] and state.incoming_count(Owner.RAW) == 0
		and state.stock_count(Owner.RAW) + state.stock_count(Owner.DRESSER) == 2
		and state.validate().is_empty(),
		"Same-tick unloads must commit in worker ID order and release both reservations.")

	config.storages.quarryReadyCapacity = 0
	sim = Simulation.new(config)
	expect(sim.stall_diagnostic(0.2).is_empty(), "The watchdog must wait for its threshold.")
	sim.step_simulation()
	sim.step_simulation()
	var diagnostic := sim.stall_diagnostic(0.2)
	expect(not diagnostic.is_empty() and diagnostic.buffers[Owner.QUARRY].free == 0
		and diagnostic.workers.has(first), "A stalled pipeline must report buffers and worker state.")


func check_porter_load_speed(balance: Dictionary) -> void:
	var config := balance.duplicate(true)
	config.workers.porter.capacity = State.MAX_PORTER_CAPACITY
	var state := State.new(config)
	var quarry := Quarry.new(state, config.workers)
	var porter := state.worker(Owner.FIRST_PORTER)
	for id in range(State.MAX_PORTER_CAPACITY):
		state._move(id, Owner.UNMINED, Owner.QUARRY)
	quarry.assign_tasks()
	var rates: Array[float] = []
	for phase in porter.timing_snapshot().phases:
		if not phase.route.is_empty():
			rates.append(phase.rate)
	expect(rates.size() == State.MAX_PORTER_CAPACITY + 1, "A full quarry batch has a leg for each load size.")
	for count in range(rates.size()):
		var expected := float(config.workers.porter.emptySpeed) if count == 0 else \
			float(config.workers.porter.loadedSpeed) * pow(float(config.workers.porter.extraItemSpeedMultiplier), count - 1)
		expect(is_equal_approx(rates[count], expected), "Porter movement rate with %d pieces." % count)

	state = State.new(config)
	quarry = Quarry.new(state, config.workers)
	porter = state.worker(Owner.FIRST_PORTER)
	for id in range(State.MAX_PORTER_CAPACITY):
		state._move(id, Owner.UNMINED, Owner.WORKSHOP_OUTPUT)
	quarry.assign_tasks()
	expect(state.incoming_count(Owner.FINISHED) == State.MAX_PORTER_CAPACITY,
		"A porter can reserve a full batch of bricks at the workshop.")
	for event in porter.advance(60.0):
		quarry.apply_completion(event)
	expect(state.stock_count(Owner.FINISHED) == State.MAX_PORTER_CAPACITY
		and state.stock(Owner.FINISHED)[0] == State.MAX_PORTER_CAPACITY - 1
		and state.stock_count(porter.id) == 0 and state.validate().is_empty(),
		"Unload every brick once, starting with the top of the stack.")


func check_full_production(balance: Dictionary, stress_buffers: bool,
		porter_count: int = 1, porter_capacity: int = 1) -> void:
	var config := balance.duplicate(true)
	config.workers.porter.count = porter_count
	config.workers.porter.capacity = porter_capacity
	if stress_buffers:
		config.workers.miner.mineSeconds = 0.1
		config.workers.miner.moveSpeed = 100.0
		config.workers.porter.emptySpeed = 100.0
		config.workers.porter.loadedSpeed = 100.0
		config.workers.porter.loadSeconds = 0.1
		config.workers.porter.unloadSeconds = 0.1

	var sim := Simulation.new(config)
	var state := sim.state
	var full_buffers := {}
	var placed := 0
	var rows := 0
	var next_row_end := state.geometry.row_size(rows)
	var rebuilds := 0
	var platform_moved := false
	var operated_lift := false
	var assisted_lifts := 0
	var timed_lift := state.worker(Owner.LIFT)
	for tick in range(400000):
		var old_row := state.current_row
		var old_platform := state.stock(Owner.PLATFORM)
		var builder := state.worker(Owner.BUILDER)
		var was_rebuilding := builder.fsm_state == &"rebuild_platform"
		var events := sim.step_simulation()
		if state.current_row == 0:
			expect(timed_lift.fsm_state == &"idle" and state.stock_count(Owner.LIFT) == 0
				and builder.position.y == 0.0, "First row stays at ground level.")
		if timed_lift.fsm_state == &"lift_brick":
			operated_lift = true
			var operator := state.worker(state.lift_operator_id())
			expect(operator != null and operator.fsm_state == &"operate_lift"
				and operator.position == state.geometry.lift_operator_position(),
				"Loaded lift only moves while a worker turns the crank.")
			if operator != null and operator.id != Owner.BUILDER:
				for id in state.worker_ids():
					if id != operator.id:
						expect(state.worker(id).fsm_state not in [&"walk_to_lift", &"operate_lift"],
							"Only one worker is assigned to the crank.")
		for event in events:
			if event.state == &"operate_lift" and event.worker_id != Owner.BUILDER:
				assisted_lifts += 1
		for entry in [[Owner.QUARRY, "quarryReadyCapacity"], [Owner.RAW, "raw"],
				[Owner.FINISHED, "finished"], [Owner.PLATFORM, "platform"]]:
			var owner: int = entry[0]
			var capacity := int(config.storages[entry[1]])
			var physical := state.stock_count(owner)
			if physical + state.incoming_count(owner) > capacity:
				expect(false, "Buffer capacity exceeded at tick %d." % tick)
				return
			if physical == capacity:
				full_buffers[owner] = true

		if state.placed_count() != placed:
			placed += 1
			if placed == next_row_end:
				rows += 1
				next_row_end += state.geometry.row_size(rows)
			expect(state.placed_count() == placed and state.completed_rows == rows
				and state.currency == 120 + placed * 10 + rows * 50,
				"Each placement must credit exactly its brick and row income.")
		if state.current_row != old_row:
			rebuilds += 1
			expect(was_rebuilding and state.current_row == old_row + 1
				and state.stock(Owner.PLATFORM) == old_platform
				and builder.fsm_state == &"climb_to_platform",
				"Rebuilding must preserve the platform stock before the builder climbs.")
		if builder.fsm_state == &"rebuild_platform":
			var position := state.platform_position()
			var route := state.geometry.platform_to_next_row(state.current_row)
			expect(is_equal_approx(position.x, route[0].x) or is_equal_approx(position.y, route[2].y),
				"The platform must move vertically and then horizontally along the scaffold.")
			platform_moved = platform_moved or (position != route[0] and position != route[2])
		if builder.fsm_state in [&"rebuild_platform", &"climb_to_platform"]:
			expect(state.task_resource_ids(Owner.LIFT).is_empty(),
				"The lift must wait during rebuilding and climbing.")
		if tick % 100 == 0 and not state.validate().is_empty():
			expect(false, "Full production invariant violated at tick %d: %s" % [tick, state.validate()])
			return
		if tick % 100 == 0:
			var diagnostic := sim.stall_diagnostic(60.0)
			if not diagnostic.is_empty():
				expect(false, "Production stalled at tick %d: %s" % [tick, diagnostic])
				return
		if state.finished:
			break

	if stress_buffers:
		expect(full_buffers.has(Owner.QUARRY) and full_buffers.has(Owner.RAW)
			and full_buffers.has(Owner.FINISHED), "Stress run exercises the upstream buffer limits.")
		expect(assisted_lifts > 0, "Idle workers operate the lift while the builder has other work.")
	expect(state.finished and placed == 900 and rows == 30 and rebuilds == 29
		and platform_moved and operated_lift and state.current_row == 29 and state.validate().is_empty(),
		"The full pipeline must finish with 900 bricks, 30 rows and 29 rebuilds.")
	for worker_id in state.worker_ids():
		expect(state.stock_count(worker_id) == 0 and state.task_resource_ids(worker_id).is_empty(),
			"Completed production must leave no cargo or reservation for worker %d." % worker_id)
	var final_time := sim.elapsed_seconds()
	expect(sim.step_simulation().is_empty() and sim.elapsed_seconds() == final_time
		and state.currency == 10620, "Victory must stop ticks and preserve the final balance.")
	print("Full production (stress=%s, porters=%d, capacity=%d): %d bricks, %d rows, %d income, %.1f seconds, %d assisted lifts, full buffers: %s" %
		[stress_buffers, porter_count, porter_capacity, placed, rows, state.currency - 120, final_time, assisted_lifts, full_buffers.keys()])

func check_builder_workshop_pickup(balance: Dictionary) -> void:
	var config := balance.duplicate(true)
	config.storages.quarryReadyCapacity = 0
	var sim := Simulation.new(config)
	var state := sim.state
	var brick := state.geometry.row_size(0)
	for id in range(brick):
		state._move(id, Owner.UNMINED, Owner.PLACED)
	state._move(brick, Owner.UNMINED, Owner.WORKSHOP_OUTPUT)
	state.current_row = 1
	state.completed_rows = 1
	state.row_start = brick
	state.worker(Owner.BUILDER).position = state.geometry.platform(1)
	sim.step_simulation()
	expect(state.pickup_targets(Owner.BUILDER) == [brick] and state.stock_count(Owner.BUILDER) == 0,
		"Builder reserves an unclaimed workshop brick before picking it up.")
	expect(state.task_resource_ids(Owner.FIRST_PORTER).is_empty(), "Porter cannot claim the same brick.")
	for tick in range(200):
		sim.step_simulation()
		if state.worker(Owner.BUILDER).fsm_state == &"walk_to_lift_base":
			break
	expect(state.worker(Owner.BUILDER).fsm_state == &"walk_to_lift_base" and state.stock(Owner.BUILDER) == [brick],
		"Builder takes the workshop brick to the lift.")
	var restored = Simulation.from_dict(config, sim.to_dict())
	if restored == null:
		expect(false, "Save the builder's loaded trip to the lift.")
		return
	var worker: State.Worker = restored.state.worker(Owner.BUILDER)
	for tick in range(200):
		restored.step_simulation()
		if worker.fsm_state == &"unload_at_lift":
			break
	expect(worker.fsm_state == &"unload_at_lift" and worker.position == state.geometry.finished_storage()
		and restored.state.stock(Owner.BUILDER) == [brick],
		"The builder stops at the lift to unload the workshop brick before turning back.")
	restored = Simulation.from_dict(config, restored.to_dict())
	if restored == null:
		expect(false, "Restore the builder while unloading at the lift.")
		return
	worker = restored.state.worker(Owner.BUILDER)
	for tick in range(100):
		restored.step_simulation()
		if worker.fsm_state == &"walk_to_lift":
			break
	expect(worker.fsm_state == &"walk_to_lift" and restored.state.stock(Owner.BUILDER).is_empty()
		and restored.state.stock(Owner.FINISHED) == [brick],
		"The builder walks to the crank only after the brick is placed at the lift.")
	for tick in range(200):
		restored.step_simulation()
		if restored.state.placed_count() > brick:
			break
	expect(restored.state.stock(Owner.PLACED).back() == brick and restored.state.placed_count() == brick + 1
		and worker.fsm_state == &"return_to_platform" and restored.state.stock(Owner.BUILDER).is_empty()
		and restored.state.validate().is_empty(), "The builder places the same brick before returning empty.")


func check_lift_assistance(balance: Dictionary) -> void:
	for helper in [Owner.DRESSER, Owner.FIRST_PORTER]:
		var config := balance.duplicate(true)
		config.storages.quarryReadyCapacity = 0
		config.workers.builder.placeSeconds = 8.0
		var sim := Simulation.new(config)
		var state := sim.state
		var row := 1
		var first_brick := state.geometry.row_size(0)
		for id in range(first_brick):
			state._move(id, Owner.UNMINED, Owner.PLACED)
		state.current_row = row
		state.completed_rows = row
		state.row_start = first_brick
		state.worker(Owner.BUILDER).position = state.geometry.platform(row)
		var lifted_brick := first_brick + 1
		state._move(first_brick, Owner.UNMINED, Owner.PLATFORM)
		state._move(lifted_brick, Owner.UNMINED, Owner.FINISHED)
		if helper != Owner.DRESSER:
			state._move(first_brick + 2, Owner.UNMINED, Owner.RAW)
		sim.step_simulation()
		expect(state.lift_operator_id() == helper and state.worker(Owner.LIFT).fsm_state == &"idle",
			"Free worker %d walks to the lift before its trip starts." % helper)
		var seen := {}
		for tick in range(1500):
			var phase := state.worker(helper).fsm_state
			if phase in [&"walk_to_lift", &"operate_lift", &"return_from_lift"] and not seen.has(phase):
				seen[phase] = true
				var restored = Simulation.from_dict(config, sim.to_dict())
				expect(restored != null and restored.to_dict() == sim.to_dict(),
					"Assistance phase %s restores without losing progress." % phase)
			if state.resource_record(lifted_brick).owner == Owner.PLACED:
				break
			sim.step_simulation()
		expect(seen.size() == 3 and state.resource_record(lifted_brick).owner == Owner.PLACED
			and state.validate().is_empty(), "The same brick is raised by a helper and placed by the builder.")


func check_miner_stays_at_lift(balance: Dictionary) -> void:
	var config := balance.duplicate(true)
	config.storages.quarryReadyCapacity = 0
	config.workers.miner.moveSpeed = 100.0
	config.workers.dresser.processSeconds = 60.0
	var sim := Simulation.new(config)
	var state := sim.state
	var first_brick := State.RESOURCE_COUNT - 4
	for id in range(first_brick):
		state._move(id, Owner.UNMINED, Owner.PLACED)
	state.current_row = 28
	state.completed_rows = 28
	state.row_start = first_brick
	state._move(first_brick, Owner.UNMINED, Owner.PLATFORM)
	state._move(first_brick + 1, Owner.UNMINED, Owner.FINISHED)
	state._move(first_brick + 2, Owner.UNMINED, Owner.FINISHED)
	state._move(first_brick + 3, Owner.UNMINED, Owner.RAW)
	state.worker(Owner.BUILDER).position = state.geometry.platform(28)
	state.worker(Owner.MINER).position = state.geometry.quarry_cell(State.RESOURCE_COUNT - 1)
	sim.step_simulation()
	expect(state.lift_operator_id() == Owner.MINER, "The exhausted miner walks to the lift once.")
	var seen := {}
	var lifted := 0
	var saw_wait_on_next_row := false
	var saw_builder_delivery := false
	for tick in range(1500):
		var miner := state.worker(Owner.MINER)
		var builder := state.worker(Owner.BUILDER)
		if not seen.has(miner.fsm_state):
			seen[miner.fsm_state] = true
			var restored = Simulation.from_dict(config, sim.to_dict())
			if restored == null or restored.to_dict() != sim.to_dict():
				expect(false, "Restore miner phase %s at the lift." % miner.fsm_state)
				return
			sim = restored
			state = sim.state
		if seen.has(&"operate_lift") and (miner.position != state.geometry.lift_operator_position()
				or miner.fsm_state not in [&"operate_lift", &"exhausted"]):
			expect(false, "The miner must stay at the crank between trips.")
			return
		if builder.fsm_state in [&"walk_to_lift", &"operate_lift"]:
			expect(false, "The builder leaves the crank to the stationed miner.")
			return
		if seen.has(&"operate_lift") and state.current_row == 29 and miner.fsm_state == &"exhausted" \
				and state.stock_count(Owner.FINISHED) == 0 and builder.fsm_state == &"idle":
			saw_wait_on_next_row = true
		saw_builder_delivery = saw_builder_delivery or builder.fsm_state == &"unload_at_lift"
		for event in sim.step_simulation():
			if event.state == &"lift_brick":
				lifted += 1
				if lifted == 1:
					expect(state.stock(Owner.LIFT) == [first_brick + 2]
						and state.lift_operator_id() == Owner.MINER, "The miner immediately lifts the next waiting brick.")
		if state.finished:
			break
	expect(state.finished and lifted == 3 and saw_wait_on_next_row and saw_builder_delivery
		and state.validate().is_empty(), "The miner waits through the row change and resumes when the builder brings the last brick.")


func check_purchase_limits(balance: Dictionary) -> void:
	var sim := Simulation.new(balance, false)
	var state := sim.state
	var economy := sim.economy
	var commands := PurchaseCommands.new(sim)
	var saves := [0]
	commands.save_requested.connect(func(): saves[0] += 1)
	var prices := {
		"MINER_SPEED": [40, 60, 90, 135, 205, 305, 455],
		"DRESSER_SPEED": [35, 55, 80, 120, 175, 265, 400],
		"BUILDER_SPEED": [45, 70, 100, 150, 230, 340, 515],
		"PORTER_SPEED": [60, 90, 135, 205, 305, 455, 685],
		"PORTER_CAPACITY": [200, 650, 1800, 1800, 1800, 1800, 1800],
		"HIRE_PORTER": [100, 170, 290, 490, 835, 1420, 2415],
	}
	var total_purchases := 0
	for code: String in prices:
		var level := 1
		for price: int in prices[code]:
			if economy.next_price(state, code) != price:
				failures.append("Wrong price for %s at level %d" % [code, level])
			state.currency = price - 1
			if commands.purchase(code, level) or state.currency != price - 1:
				failures.append("Unaffordable purchase changed state: " + code)
			state.currency = price
			if not commands.purchase(code, level) or state.currency != 0:
				failures.append("Exact balance purchase failed: " + code)
			state.currency = 10000
			if commands.purchase(code, level) or state.currency != 10000:
				failures.append("Repeated purchase changed state: " + code)
			level += 1
			total_purchases += 1
		if economy.purchase_level(state, code) != level or economy.next_price(state, code) != -1 \
				or commands.purchase(code, level):
			failures.append("Purchase limit failed: " + code)
	if saves[0] != total_purchases or state.currency != 10000:
		failures.append("Save request count or final purchase balance is wrong.")
	for id in range(Owner.FIRST_PORTER, Owner.FIRST_PORTER + state.porter_count):
		var porter := state.worker(id)
		if porter.position != state.geometry.raw_storage() or not state.stock(id).is_empty() \
				or not is_equal_approx(porter.speed_multiplier, pow(1.15, 7)):
			failures.append("Hired porter has wrong position, cargo, or speed.")
	var fresh := Simulation.new(balance)
	fresh.state.finished = true
	var finished_commands := PurchaseCommands.new(fresh)
	for code: String in prices:
		if fresh.economy.next_price(fresh.state, code) != -1 or finished_commands.purchase(code, 1):
			failures.append("Purchase allowed after victory: " + code)
	if fresh.state.currency != int(balance.economy.startCoins) or commands.purchase("UNKNOWN", 1):
		failures.append("Victory balance changed or unknown purchase accepted.")


func check_purchases_during_production(balance: Dictionary) -> void:
	var sim := Simulation.new(balance)
	var state := sim.state
	var commands := PurchaseCommands.new(sim)
	state.currency = 100000
	var spending := 0
	var pending := {
		"move_to_cell": [Owner.MINER, "MINER_SPEED"],
		"mine": [Owner.MINER, "MINER_SPEED"],
		"walk_to_pickup": [Owner.FIRST_PORTER, "PORTER_SPEED"],
		"load": [Owner.FIRST_PORTER, "PORTER_SPEED"],
		"walk_to_storage": [Owner.FIRST_PORTER, "PORTER_SPEED"],
		"unload": [Owner.FIRST_PORTER, "PORTER_SPEED"],
		"process_brick": [Owner.DRESSER, "DRESSER_SPEED"],
		"walk_to_brick": [Owner.BUILDER, "BUILDER_SPEED"],
		"place_brick": [Owner.BUILDER, "BUILDER_SPEED"],
		"return_to_platform": [Owner.BUILDER, "BUILDER_SPEED"],
		"climb_to_platform": [Owner.BUILDER, "BUILDER_SPEED"],
		"rebuild_platform": [Owner.BUILDER, "BUILDER_SPEED"],
	}
	for tick in range(150000):
		for phase: String in pending.keys():
			var worker_id: int = pending[phase][0]
			var worker := state.worker(worker_id)
			if worker.fsm_state != StringName(phase):
				continue
			var code: String = pending[phase][1]
			var before := worker.timing_snapshot()
			var reserved := state.task_resource_ids(worker_id)
			var cargo := state.stock(worker_id)
			var level := sim.economy.purchase_level(state, code)
			spending += sim.economy.next_price(state, code)
			if not commands.purchase(code, level):
				failures.append("Mid-phase purchase failed: " + phase)
			var after := worker.timing_snapshot()
			var factor := 1.15 if code == "PORTER_SPEED" else 1.18
			if not is_equal_approx(after.speed_multiplier, before.speed_multiplier * factor):
				failures.append("Wrong speed multiplier during " + phase)
			after.speed_multiplier = before.speed_multiplier
			if before != after or state.task_resource_ids(worker_id) != reserved \
					or state.stock(worker_id) != cargo:
				failures.append("Purchase changed phase progress, cargo or reservations: " + phase)
			if phase == "walk_to_pickup":
				spending += sim.economy.next_price(state, "PORTER_CAPACITY")
				if not commands.purchase("PORTER_CAPACITY", 1) \
						or state.task_resource_ids(worker_id) != reserved:
					failures.append("Capacity purchase changed an assigned trip.")
			pending.erase(phase)
		sim.step_simulation()
		if state.finished:
			break
	if not pending.is_empty() or not state.finished or state.placed_count() != 900 \
			or state.currency != 100000 - spending + 10500:
		failures.append("Purchased production failed or missed phases: %s" % str(pending.keys()))

func check_purchase_effects(balance: Dictionary) -> void:
	var sim := Simulation.new(balance, false)
	var commands := PurchaseCommands.new(sim)
	var miner := sim.state.worker(Owner.MINER)
	miner.queue_move(&"move_to_cell", PackedVector2Array([
		miner.position, miner.position + Vector2.RIGHT,
	]), 1.0)
	miner.queue_work(&"mine", 2.0, 1.0)
	sim.step_simulation()
	expect(commands.purchase("MINER_SPEED", 1), "Could not buy miner speed during movement.")
	sim.step_simulation()
	expect(is_equal_approx(miner.remaining_distance, 0.782), "Movement must use the new speed immediately.")
	for tick in range(7):
		sim.step_simulation()
	expect(miner.fsm_state == &"mine" and is_equal_approx(miner.remaining_work, 1.956),
		"Queued work must use the new speed and consume the remaining fraction of the tick.")

	var state := sim.state
	var quarry := Quarry.new(state, balance.workers)
	for id in range(3):
		state._move(id, Owner.UNMINED, Owner.QUARRY)
	quarry.assign_tasks()
	var porter := state.worker(Owner.FIRST_PORTER)
	state.currency = 200
	expect(commands.purchase("PORTER_CAPACITY", 1)
		and state.task_resource_ids(porter.id).size() == 1,
		"Capacity purchase must preserve the assigned batch.")
	for event in porter.advance(60.0):
		quarry.apply_completion(event)
	quarry.assign_tasks()
	expect(state.stock_count(Owner.RAW) == 1
		and state.task_resource_ids(porter.id).size() == 2 and state.validate().is_empty(),
		"The next trip must use the increased capacity without losing resources.")

func check_saves(balance: Dictionary) -> void:
	var path := OS.get_environment("TEMP").path_join("piramida-save-test-" + str(OS.get_process_id()) + ".json")
	if OS.get_environment("TEMP").is_empty():
		path = "user://piramida-save-test-%d.json" % OS.get_process_id()
	check_save_files(balance, path)
	for suffix in ["", ".bak", ".tmp", ".bak.tmp"]:
		if FileAccess.file_exists(path + suffix):
			DirAccess.remove_absolute(path + suffix)


func check_save_files(balance: Dictionary, path: String) -> void:
	balance = balance.duplicate(true)
	balance.workers.porter.count = 2
	balance.workers.porter.capacity = 4
	balance.simulation.autosaveSeconds = 0.1
	var service := SaveService.new(balance, path)
	var continuous := Simulation.new(balance)
	var interrupted := Simulation.new(balance)
	var session := GameSession.new(interrupted, service, balance)
	expect(service.load_game().status == SaveService.Status.MISSING, "Missing save")
	expect(session.purchases.purchase("MINER_SPEED", 1), "Purchase requests save")
	expect(continuous.economy.try_purchase(continuous.state, "MINER_SPEED", 1), "Mirror purchase")
	continuous.step_simulation()
	session.step_simulation()
	expect(session.last_save_error == OK and FileAccess.file_exists(path), "Purchase/interval saved")
	expect(not FileAccess.file_exists(path + ".bak"), "Purchase and interval coalesced")
	continuous.step_simulation()
	session.step_simulation()
	expect(FileAccess.file_exists(path + ".bak"), "Interval alone saved")
	var loaded := service.load_game()
	if loaded.status != SaveService.Status.OK:
		expect(false, "Read initial save, status %d" % loaded.status)
		return
	var legacy_text := FileAccess.get_file_as_string(path)
	interrupted = loaded.simulation
	expect(interrupted.to_dict() == continuous.to_dict(), "Exact initial restore")
	var phases := {}
	var checked_row_save := false
	session = GameSession.new(interrupted, service, balance)
	# Keep the interval out of the way while testing the first row trigger.
	session._next_save_at = INF
	for index in range(200000):
		var row_count := interrupted.state.completed_rows
		var expected := continuous.step_simulation()
		var actual := session.step_simulation() if not checked_row_save else interrupted.step_simulation()
		if actual != expected:
			expect(false, "Restored phase events diverged at tick %d" % index)
			return
		if not checked_row_save and interrupted.state.completed_rows > row_count:
			var row_save := service.load_game()
			expect(row_save.status == SaveService.Status.OK and row_save.simulation.to_dict() == interrupted.to_dict(), "Row completion saved")
			checked_row_save = true
		var checkpoint := index % 10000 == 0 or interrupted.state.finished
		for id in interrupted.state.worker_ids():
			var agent := interrupted.state.worker(id)
			var key := "%d/%s" % [agent.role, agent.fsm_state]
			if not phases.has(key):
				phases[key] = true
				checkpoint = true
		if checkpoint:
			var error := service.save_game(interrupted)
			var result := service.load_game()
			if error != OK or result.status != SaveService.Status.OK:
				expect(false, "Checkpoint failed at tick %d, error %d, status %d" % [index, error, result.status])
				return
			interrupted = result.simulation
			if not checked_row_save:
				session = GameSession.new(interrupted, service, balance)
				session._next_save_at = INF
			if interrupted.to_dict() != continuous.to_dict():
				expect(false, "Snapshot diverged at tick %d" % index)
				return
		if interrupted.state.finished:
			break
	expect(interrupted.state.finished and checked_row_save and phases.has("3/walk_to_workshop")
		and phases.has("4/return_to_raw_storage"),
		"Full run and checkpoints for both brick collection roles, found %s" % [phases.keys()])

	var backup_text := FileAccess.get_file_as_string(path + ".bak")
	expect(service._write(path, "{truncated") == OK, "Damage primary fixture")
	var recovery := service.load_game()
	expect(recovery.status == SaveService.Status.OK and recovery.get("recovered", false), "Backup recovery")
	if recovery.status != SaveService.Status.OK:
		return
	expect(service.save_game(recovery.simulation) == OK and FileAccess.get_file_as_string(path + ".bak") == backup_text,
		"Recovery preserves valid backup")

	var envelope: Dictionary = JSON.parse_string(legacy_text)
	var payload: Dictionary = JSON.parse_string(envelope.payload)
	payload["snapshotUtc"] = payload.savedAtUtc
	payload.erase("savedAtUtc")
	envelope.schemaVersion = 1
	envelope.payload = JSON.stringify(payload, "", true, true)
	envelope.checksum = service._checksum(1, envelope.payload)
	expect(service._write(path, JSON.stringify(envelope)) == OK, "Write v1 fixture")
	var migrated := service.load_game()
	expect(migrated.status == SaveService.Status.OK and not migrated.get("recovered", false)
		and migrated.saved_at_utc == payload.snapshotUtc, "Sequential v1 migration")

	envelope.checksum = "wrong"
	expect(service._write(path, JSON.stringify(envelope)) == OK
		and service.load_game().get("recovered", false), "Checksum mismatch uses backup")
	payload.simulation.model.stocks[str(Owner.PLACED)].append(0)
	envelope.payload = JSON.stringify(payload, "", true, true)
	envelope.checksum = service._checksum(1, envelope.payload)
	expect(service._write(path, JSON.stringify(envelope)) == OK
		and service.load_game().get("recovered", false), "Invalid ownership rejected despite valid checksum")

	envelope.schemaVersion = SaveService.SCHEMA_VERSION + 1
	var future := JSON.stringify(envelope)
	expect(service._write(path, future) == OK, "Write future fixture")
	expect(service.load_game().status == SaveService.Status.UNSUPPORTED
		and service.save_game(interrupted) == ERR_UNAVAILABLE
		and FileAccess.get_file_as_string(path) == future, "Protect future save")


func check_lifecycle(balance: Dictionary) -> void:
	var path := OS.get_environment("TEMP").path_join("piramida-lifecycle-%d.json" % OS.get_process_id())
	if OS.get_environment("TEMP").is_empty():
		path = "user://" + path
	var service := SaveService.new(balance, path)
	var controller := Lifecycle.new(balance, service, 100000)
	var game := controller.session.simulation
	var start := game.to_dict()
	controller.set_paused(true)
	controller.advance_frame(600.0)
	expect(game.to_dict() == start and not controller.session.purchases.purchase("MINER_SPEED", 1),
		"Screen pause freezes production and disables purchases")
	controller = Lifecycle.new(balance, service, 101000)
	expect(controller.mode == Lifecycle.Mode.PAUSED and controller.session.simulation.to_dict() == start,
		"Loading a paused snapshot does not grant offline production")
	controller.enter_background(102000)
	controller.enter_background(102030)
	controller.enter_foreground(101999)
	controller.advance_frame(0.0)
	expect(controller.mode == Lifecycle.Mode.PAUSED and controller.session.simulation.to_dict() == start,
		"Backwards clock grants zero production")
	controller.enter_background(103000)
	controller.enter_background(103001)
	controller.enter_foreground(103003)
	controller.advance_frame(0.0, 5, 1000000)
	expect(controller.mode == Lifecycle.Mode.RESTORING and is_equal_approx(controller.session.simulation.elapsed_seconds(), 0.5)
		and not controller.session.purchases.enabled, "Offline work is sliced and purchases stay disabled")
	controller.enter_background(103004)
	controller.advance_frame(500.0)
	expect(is_equal_approx(controller.session.simulation.elapsed_seconds(), 0.5), "Background suspends ongoing recovery")
	controller.enter_foreground(103010)
	controller.advance_frame(0.0, 5, 1000000)
	expect(is_equal_approx(controller.session.simulation.elapsed_seconds(), 1.0), "Foreground resumes the same batch")
	controller.close(103011)
	controller = Lifecycle.new(balance, service, 104000)
	controller.advance_frame(0.0, 100, 1000000)
	expect(controller.mode == Lifecycle.Mode.PAUSED and is_equal_approx(controller.session.simulation.elapsed_seconds(), 3.0),
		"Restart during recovery commits the original interval exactly once")
	controller = Lifecycle.new(balance, service, 105000)
	expect(controller.mode == Lifecycle.Mode.PAUSED and is_equal_approx(controller.session.simulation.elapsed_seconds(), 3.0),
		"Committed absence is consumed on reload")

	var continuous: Simulation = Simulation.from_dict(balance, controller.session.simulation.to_dict())
	controller.set_paused(false)
	controller.enter_background(106000)
	controller.enter_foreground(106000 + 5 * 3600)
	var reports: Array[Dictionary] = []
	var online: Array[Array] = []
	controller.offline_completed.connect(func(summary: Dictionary) -> void: reports.append(summary))
	controller.online_events.connect(func(events: Array[Dictionary]) -> void: online.append(events))
	for index in range(144000):
		continuous.step_simulation()
	var frames := 0
	while controller.mode == Lifecycle.Mode.RESTORING and frames < 1000:
		controller.advance_frame(0.0, 512, 1000000)
		frames += 1
	var result := controller.session.simulation
	expect(controller.mode == Lifecycle.Mode.ACTIVE and frames > 1
		and result.to_dict() == continuous.to_dict(), "Four-hour offline cap matches continuous production")
	expect(online.is_empty() and reports.size() == 1 and reports[0].credited_seconds == 14400.0
		and reports[0].placed == continuous.state.placed_count()
		and reports[0].currency == continuous.state.currency - int(balance.economy.startCoins),
		"Offline emits one summary and no online events")
	for suffix in ["", ".bak", ".tmp", ".bak.tmp"]:
		if FileAccess.file_exists(path + suffix):
			DirAccess.remove_absolute(path + suffix)
