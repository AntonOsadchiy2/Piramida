extends SceneTree

const Blueprint = preload("res://scripts/domain/blueprint.gd")
const Wallpaper = preload("res://scripts/application/wallpaper.gd")
const State = preload("res://scripts/domain/game_state.gd")
const Construction = preload("res://scripts/simulation/construction_production.gd")

func _initialize() -> void:
	var balance: Dictionary = Wallpaper.wallpaper_balance(JSON.parse_string(
		FileAccess.get_file_as_string("res://data/balance.json")))
	var checked := Blueprint.validate({"version": 2, "blocks": [
		{"x": 0, "y": 0, "size": 4, "type": "stone"},
		{"x": 4, "y": 0, "size": 2, "type": "stone"},
		{"x": 6, "y": 0, "size": 1, "type": "stone"},
		{"x": 58, "y": 0, "size": 1, "type": "stone"},
		{"x": 6, "y": 1, "size": 1, "type": "stone"},
	]})
	balance.world["blueprintBlocks"] = checked.blocks
	var state := State.new(balance)
	for id in range(4):
		state._move(id, State.Owner.UNMINED, State.Owner.PLACED)
	state.current_row = 1
	state.row_start = 4
	state.completed_rows = 1
	var production := Construction.new(state, balance)
	production._refresh_routes()
	var target: Vector2 = state.geometry.brick_origin(1, 0)
	var landing := state.delivery_point
	print("delivery=", landing, " target=", target, " old=", state.geometry.platform(1))
	if not landing.is_finite() or landing.distance_to(target) > 3.0 * state.geometry.brick_size().x:
		push_error("Delivery must land on a nearby scaffold")
		quit(1)
		return
	state._move(4, State.Owner.UNMINED, State.Owner.FINISHED)
	production._start_manual_lift(State.Owner.MINER)
	var route := state.worker(State.Owner.LIFT).movement_route()
	if route.is_empty() or not route[-1].is_equal_approx(landing):
		push_error("Lift route ends away from delivery")
		quit(1)
		return
	for event in state.worker(State.Owner.LIFT).advance(100.0):
		production.apply_completion(event)
	if state.stock_count(State.Owner.PLATFORM) != 1 \
			or not state.delivery_point.is_equal_approx(landing):
		push_error("Lift cargo was not unloaded on the selected scaffold")
		quit(1)
		return
	var saved: Array = state.to_dict().delivery_point
	if saved.size() != 2 or not Vector2(saved[0], saved[1]).is_equal_approx(landing):
		push_error("Delivery point was not saved")
		quit(1)
		return
	var builder := state.worker(state.active_builder_id)
	for tick in range(1000):
		for event in builder.advance(0.1):
			production.apply_completion(event)
		if state.placed_count() == 5:
			break
		production.assign_tasks()
	if state.placed_count() != 5:
		push_error("Builder failed to collect and place scaffold cargo: %s" % builder.fsm_state)
		quit(1)
		return
	print("PASS: lift delivery and placement near next block")
	quit()
