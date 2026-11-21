extends SceneTree

const Blueprint = preload("res://scripts/domain/blueprint.gd")
const State = preload("res://scripts/domain/game_state.gd")
const Simulation = preload("res://scripts/simulation/simulation_runner.gd")


func _initialize() -> void:
	var balance: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	balance.world.blueprintBlocks = Blueprint.validate({"version": 2, "blocks": [
		{"x": 0, "y": 0, "size": 4},
		{"x": 6, "y": 0},
		{"x": 14, "y": 0},
		{"x": 6, "y": 1},
		{"x": 14, "y": 1},
	]}).blocks
	balance.workers.builder.count = 2
	var simulation := Simulation.new(balance)
	var state := simulation.state
	var builders := {}
	var previous_count := 0
	var first_row := PackedVector2Array()
	for tick in range(10000):
		var events := simulation.step_simulation()
		for event in events:
			if event.has("placement_index"):
				var index: int = event.placement_index
				assert(index == previous_count)
				assert(state.owner_of(index) == State.Owner.PLACED)
				previous_count += 1
				builders[event.worker_id] = true
				if index == 2:
					first_row = state.scaffold_paths[0]
		if state.current_row == 1:
			assert(state.scaffold_paths.size() == 1)
			assert(state.scaffold_paths[0].slice(0, first_row.size()) == first_row)
			assert(state.scaffold_paths[0][-1].y == first_row[-1].y)
			assert(state.delivery_point == state.scaffold_paths[-1][-1])
		if state.finished:
			break
	assert(state.finished and previous_count == 5 and builders.size() == 2)
	assert(state.validate().is_empty())
	print("PASS: two builders keep their routes and resources as the scaffold grows")
	quit()
