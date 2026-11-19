extends SceneTree

const Blueprint = preload("res://scripts/domain/blueprint.gd")
const State = preload("res://scripts/domain/game_state.gd")
const Simulation = preload("res://scripts/simulation/simulation_runner.gd")
const Construction = preload("res://scripts/simulation/construction_production.gd")
const Saves = preload("res://scripts/application/save_service.gd")

func _initialize() -> void:
	var balance: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	var simulation := Simulation.new(balance)
	var saves := Saves.new(balance, "user://construction-save-test/save.json")
	var seen := {}
	for tick in range(15000):
		var builder := simulation.state.worker(simulation.state.active_builder_id)
		var phase := String(builder.fsm_state)
		if phase in ["walk_to_brick", "place_brick", "return_to_platform",
				"rebuild_platform", "climb_to_platform"] and not seen.has(phase):
			_check_round_trip(simulation, saves, phase)
			seen[phase] = true
		if seen.size() == 5:
			break
		simulation.step_simulation()
	assert(seen.size() == 5)
	_check_waiting(balance)
	print("PASS: construction save resumes movement, work, row change and waiting")
	quit()

func _check_round_trip(simulation: Simulation, saves: Saves, phase: String) -> void:
	var original: Dictionary = simulation.to_dict()
	assert(saves.save_game(simulation) == OK)
	for _repeat in range(2):
		var result := saves.load_game()
		assert(result.status == Saves.Status.OK)
		var loaded: Simulation = result.simulation
		assert(loaded.state.validate().is_empty())
		assert(loaded.state.to_dict() == simulation.state.to_dict())
		var id := simulation.state.active_builder_id
		var before := simulation.state.worker(id)
		var after := loaded.state.worker(id)
		assert(after.position.is_equal_approx(before.position))
		assert(after.fsm_state == before.fsm_state and String(after.fsm_state) == phase)
		assert(is_equal_approx(after.remaining_work, before.remaining_work))
		assert(loaded.state.task_resource_ids(id) == simulation.state.task_resource_ids(id))
		assert(loaded.state.stock(id) == simulation.state.stock(id))
		assert(saves.save_game(loaded) == OK)
		assert(loaded.state.placed_count() == simulation.state.placed_count())
	assert(original.model == simulation.to_dict().model)
	if phase == "walk_to_brick":
		var paused: Dictionary = simulation.to_dict()
		for timing in paused.workers:
			if timing.id == simulation.state.active_builder_id:
				timing.route_waiting = true
		paused.construction_waiting[str(simulation.state.active_builder_id)] = phase
		var recovered: Simulation = Simulation.from_dict(saves._balance, paused)
		assert(recovered != null)
		assert(recovered.state.worker(simulation.state.active_builder_id).position.is_equal_approx(
			simulation.state.worker(simulation.state.active_builder_id).position))

func _check_waiting(balance: Dictionary) -> void:
	var checked := Blueprint.validate({"version": 2, "blocks": [
		{"x": 0, "y": 0, "size": 4, "type": "stone"},
		{"x": 7, "y": 0, "size": 1, "type": "stone"},
		{"x": 8, "y": 0, "size": 1, "type": "stone"},
	]})
	assert(not checked.has("error"))
	balance.world["blueprintBlocks"] = checked.blocks
	var simulation := Simulation.new(balance, false)
	simulation._construction = Construction.new(simulation.state, balance)
	var state := simulation.state
	var builder := state.worker(state.active_builder_id)
	state._move(0, State.Owner.UNMINED, State.Owner.PLACED)
	state._move(1, State.Owner.UNMINED, State.Owner.FINISHED)
	assert(simulation._construction._take_input(builder.id, State.Owner.FINISHED))
	simulation._construction._refresh_routes()
	simulation._construction._scaffolds.clear()
	simulation._construction._queue_placement()
	assert(builder.fsm_state == &"idle" and simulation._construction._waiting[builder.id] == &"walk_to_brick")
	assert(state.validate().is_empty())
	var saves := Saves.new(balance, "user://construction-save-test/waiting.json")
	assert(saves.save_game(simulation) == OK)
	for _repeat in range(2):
		var result := saves.load_game()
		assert(result.status == Saves.Status.OK)
		var loaded: Simulation = result.simulation
		assert(loaded.state.placed_count() == 1)
		assert(loaded.state.stock(builder.id) == [1])
		assert(loaded.state.task_resource_ids(builder.id) == [1])
		assert(loaded.state.validate().is_empty())
		assert(loaded._construction._waiting[builder.id] == &"walk_to_brick")
		assert(saves.save_game(loaded) == OK)
	var legacy: Dictionary = simulation.to_dict()
	legacy.erase("construction_waiting")
	for worker in legacy.workers:
		worker.erase("route_waiting")
	var migrated: Simulation = Simulation.from_dict(balance, legacy)
	assert(migrated != null)
	assert(migrated._construction._waiting[builder.id] == &"walk_to_brick")
	assert(migrated.state.stock(builder.id) == [1] and migrated.state.validate().is_empty())
