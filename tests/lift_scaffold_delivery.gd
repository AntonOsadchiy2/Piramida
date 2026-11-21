extends SceneTree

const Blueprint = preload("res://scripts/domain/blueprint.gd")
const Wallpaper = preload("res://scripts/application/wallpaper.gd")
const State = preload("res://scripts/domain/game_state.gd")
const Construction = preload("res://scripts/simulation/construction_production.gd")


func _initialize() -> void:
	var balance: Dictionary = Wallpaper.wallpaper_balance(JSON.parse_string(
		FileAccess.get_file_as_string("res://data/balance.json")))
	balance.world.blueprintBlocks = Blueprint.validate({"version": 2, "blocks": [
		{"x": 0, "y": 0, "size": 4},
		{"x": 6, "y": 0},
		{"x": 58, "y": 0},
		{"x": 6, "y": 1},
		{"x": 8, "y": 1, "size": 4},
	]}).blocks
	var state := State.new(balance)
	for id in range(3):
		state._move(id, State.Owner.UNMINED, State.Owner.PLACED)
	state.current_row = 1
	state.row_start = 3
	state.completed_rows = 1
	var production := Construction.new(state, balance)
	var builder := state.worker(state.active_builder_id)
	var lift := state.worker(State.Owner.LIFT)
	var miner := state.worker(State.Owner.MINER)
	var dresser := state.worker(State.Owner.DRESSER)
	dresser.position = state.geometry.lift_operator_position()
	var previous_tip := Vector2.INF
	for id in [3, 4]:
		var tip := state.scaffold_paths[-1][-1]
		assert(tip != previous_tip and state.delivery_point == tip)
		state._move(id, State.Owner.UNMINED, State.Owner.FINISHED)
		var operator := miner
		if id == 3:
			operator = dresser
			builder.position = tip
			production.assign_assistance()
			assert(state.lift_operator_id() == dresser.id)
			_advance(production, dresser, 0.1)
			assert(dresser.fsm_state == &"operate_lift")
		else:
			production._start_manual_lift(miner.id)
		var route := lift.movement_route()
		var reach := state.geometry.brick_size().y * state.geometry.block_size_for_resource(id)
		assert(route.size() == 4 and route[-1] == tip)
		assert(is_equal_approx(route[2].y + reach + state.geometry.lift_suspension(),
			state.geometry.lift_cable_height(1)))
		assert(state.stock(State.Owner.LIFT) == [id])
		_advance(production, lift, 100.0)
		_advance(production, operator, 100.0)
		if operator == dresser:
			assert(dresser.position == state.geometry.workshop())
		assert(state.stock(State.Owner.PLATFORM) == [id] and state.platform_position() == tip)
		var saved: Array = state.to_dict().delivery_point
		assert(Vector2(saved[0], saved[1]).is_equal_approx(tip))

		for tick in range(1000):
			production.assign_tasks()
			_advance(production, builder, 0.1)
			if state.placed_count() == id + 1:
				break
		assert(state.placed_count() == id + 1 and state.owner_of(id) == State.Owner.PLACED)
		previous_tip = tip
	assert(state.finished and state.validate().is_empty())
	print("PASS: successive 1x1 and 4x4 deliveries unload at their own scaffold tips")
	quit()


func _advance(production: Construction, worker: State.Worker, seconds: float) -> void:
	for event in worker.advance(seconds):
		production.apply_completion(event)
