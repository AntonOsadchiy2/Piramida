extends SceneTree

const Blueprint = preload("res://scripts/domain/blueprint.gd")
const State = preload("res://scripts/domain/game_state.gd")
const Construction = preload("res://scripts/simulation/construction_production.gd")


func _initialize() -> void:
	var balance: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	balance.world.blueprintBlocks = Blueprint.validate({"version": 2, "blocks": [
		{"x": 0, "y": 3, "size": 4},
		{"x": 6, "y": 3},
		{"x": 13, "y": 3},
	]}).blocks
	var state := State.new(balance)
	var production := Construction.new(state, balance)
	var builder := state.worker(state.active_builder_id)
	var first := production._placement_point()
	state._move(0, State.Owner.UNMINED, State.Owner.FINISHED)
	production.assign_tasks()
	var route := builder.movement_route()
	assert(route.size() >= 5 and route[-1] == first)
	assert(builder.position.y == 0.0 and route[0] == state.scaffold_paths[0][0])
	assert(route[2].y > route[1].y and route[2].y == route[3].y and route[4].y > route[3].y)
	for event in builder.advance(100.0):
		production.apply_completion(event)
	assert(state.placed_count() == 1)
	assert(state.scaffold_paths[0].has(first))
	assert(builder.movement_route()[0] == first)
	assert(builder.movement_route()[-1] == state.scaffold_paths[0][-1])
	assert(builder.movement_route()[-1].y == first.y)
	assert(state.validate().is_empty())
	print("PASS: builder carries a 4x4 up stairs, then continues on the same floor")
	quit()
