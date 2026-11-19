extends SceneTree

const Blueprint = preload("res://scripts/domain/blueprint.gd")
const State = preload("res://scripts/domain/game_state.gd")
const Construction = preload("res://scripts/simulation/construction_production.gd")

func _initialize() -> void:
	var balance: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	var checked := Blueprint.validate({"version": 2, "blocks": [
		{"x": 0, "y": 0, "size": 4, "type": "stone"},
		{"x": 7, "y": 0, "size": 1, "type": "stone"},
		{"x": 8, "y": 0, "size": 1, "type": "stone"},
	]})
	assert(not checked.has("error"))
	balance.world["blueprintBlocks"] = checked.blocks
	balance.workers.builder.count = 2
	var state := State.new(balance)
	var production := Construction.new(state, balance)
	var builder := state.worker(state.active_builder_id)
	state._move(0, State.Owner.UNMINED, State.Owner.PLACED)
	state._move(1, State.Owner.UNMINED, State.Owner.FINISHED)
	assert(production._take_input(builder.id, State.Owner.FINISHED))
	production._refresh_routes()
	production._scaffolds.clear()
	production._queue_placement()
	assert(builder.fsm_state == &"idle" and production._waiting.has(builder.id))
	assert(state.placed_count() == 1 and state.stock_count(builder.id) == 1)
	assert(state.task_resource_ids(builder.id) == [1] and state.validate().is_empty())
	var attempted_generation: int = production._waiting_attempt[builder.id]
	var blocked: Dictionary = production.blocked_snapshot()[str(builder.id)]
	assert(blocked.target.id == 1 and blocked.target.x == 7 and blocked.target.y == 0
		and blocked.reason != "", str(blocked))
	for _tick in range(5):
		production.assign_tasks()
		assert(state.placed_count() == 1 and state.stock_count(builder.id) == 1)
		assert(production._waiting_attempt[builder.id] == attempted_generation)
	production._route_revision = -1
	production._refresh_routes()
	production.assign_tasks()
	assert(builder.fsm_state == &"walk_to_brick")
	var placed_once := false
	var saw_return := false
	for _tick in range(1000):
		for event in builder.advance(0.1):
			production.apply_completion(event)
			if event.state == &"place_brick":
				placed_once = true
			if event.state == &"return_to_platform":
				saw_return = true
		if not state.finished:
			production.assign_tasks()
		assert(state.validate().is_empty())
		if saw_return:
			break
	assert(placed_once and saw_return and state.placed_count() == 2)
	assert(state.stock_count(builder.id) == 0 and state.task_resource_ids(builder.id).is_empty())
	assert(state.active_builder_id != builder.id)
	var second := state.worker(state.active_builder_id)
	state._move(2, State.Owner.UNMINED, State.Owner.FINISHED)
	assert(production._take_input(second.id, State.Owner.FINISHED))
	production._queue_placement()
	assert(second.fsm_state == &"walk_to_brick")
	print("PASS: missing path preserves cargo, returns and routes the next builder")
	quit()
