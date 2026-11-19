extends SceneTree

const Blueprint = preload("res://scripts/domain/blueprint.gd")
const State = preload("res://scripts/domain/game_state.gd")
const Routes = preload("res://scripts/domain/placed_route.gd")
const Construction = preload("res://scripts/simulation/construction_production.gd")


func _initialize() -> void:
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	for size in [1, 2, 4]:
		var checked := Blueprint.validate({"version": 2, "blocks": [
			{"x": 0, "y": 0, "size": size, "type": "stone"},
			{"x": size + 2, "y": 0, "size": size, "type": "stone"},
		]})
		assert(not checked.has("error"), str(checked))
		var balance := base.duplicate(true)
		balance.world["blueprintBlocks"] = checked.blocks
		var state := State.new(balance)
		state._move(0, State.Owner.UNMINED, State.Owner.PLACED)
		state._move(1, State.Owner.UNMINED, State.Owner.PLACED)
		var geometry = state.geometry
		var placed := state.placed_surface_snapshot()
		var unit: Vector2 = geometry.brick_size()
		var left: float = balance.world.pyramidLeft
		var top_y: float = size * unit.y
		var top_left := Vector2(left + 0.2 * unit.x, top_y)
		var top_right := Vector2(left + (size - 0.2) * unit.x, top_y)
		var flat: Dictionary = Routes.find_path(geometry, placed, [], top_left, top_right)
		var flat_back: Dictionary = Routes.find_path(geometry, placed, [], top_right, top_left)
		assert(flat.ok and flat_back.ok, str([size, flat, flat_back]))
		var ground := Vector2(left - unit.x, 0.0)
		assert(not Routes.find_path(geometry, placed, [], ground, top_left).ok)
		var step: Dictionary = geometry.scaffold_snapshot(placed,
			Vector2(left - 0.7 * unit.x, 0.0), top_left,
			{"section_width": 1.5 * unit.x, "max_span": 2.0 * unit.x})
		assert(step.ok, str([size, step]))
		for post: Dictionary in step.posts:
			var support := geometry.support_below(placed, Vector2((post.x0 + post.x1) * 0.5, post.y1))
			assert(not support.is_empty() and is_equal_approx(post.y0, support.y))
		var up: Dictionary = Routes.find_path(geometry, placed, [step], ground, top_left)
		var down: Dictionary = Routes.find_path(geometry, placed, [step], top_left, ground)
		assert(up.ok and down.ok, str([size, up, down]))
		var gap_x: float = left + (size + 1) * unit.x
		var gap: Dictionary = geometry.scaffold_snapshot(placed,
			Vector2(gap_x, top_y), Vector2(gap_x, top_y),
			{"section_width": 1.5 * unit.x, "max_span": 2.0 * unit.x,
				"max_void_depth": 0.1 * unit.y, "max_void_width": 0.1 * unit.x})
		assert(not gap.ok and gap.reason == "void_limit", str([size, gap]))
		var production := Construction.new(state, balance)
		production._refresh_routes()
		var saw_diagonal := false
		var saw_supported_bridge := false
		for scaffold: Dictionary in production._scaffolds:
			for section: Dictionary in scaffold.sections:
				if is_equal_approx(float(section.y), top_y) \
						and float(section.x0) < left + (size + 2) * unit.x \
						and float(section.x1) > left + size * unit.x:
					assert(section.post_ids.size() == 2 and scaffold.posts.size() >= 2)
					saw_supported_bridge = true
			for transition: Dictionary in scaffold.transitions:
				if transition.kind == "slope":
					assert(absf(transition["to"].x - transition["from"].x) >= 0.1 * unit.x)
					saw_diagonal = true
		assert(saw_diagonal)
		assert(saw_supported_bridge)
		var visible_flat := Routes.find_path(geometry, placed,
			state.scaffold_sections, top_left, top_right, {"include_surfaces": false})
		assert(visible_flat.ok, str([size, visible_flat, state.scaffold_sections]))
		var across := Routes.find_path(geometry, placed, production._scaffolds,
			top_right, Vector2(left + (size + 2.2) * unit.x, top_y))
		var back := Routes.find_path(geometry, placed, production._scaffolds,
			Vector2(left + (size + 2.2) * unit.x, top_y), top_right)
		assert(across.ok and back.ok, str([size, across, back]))
	_check_held_row_deck(base)
	_check_descent_to_raised_deck(base)
	_check_recess_and_overlapping_decks(base)
	print("PASS: scaffold acceptance flat, held deck, step, gap, return and mixed-height landings")
	quit()


func _check_held_row_deck(base: Dictionary) -> void:
	var checked := Blueprint.validate({"version": 2, "blocks": [
		{"x": 0, "y": 0, "size": 2, "type": "stone"},
		{"x": 3, "y": 0, "size": 1, "type": "stone"},
		{"x": 5, "y": 0, "size": 4, "type": "stone"},
		{"x": 10, "y": 0, "size": 1, "type": "stone"},
		{"x": 12, "y": 0, "size": 2, "type": "stone"},
		{"x": 15, "y": 0, "size": 1, "type": "stone"},
		{"x": 17, "y": 1, "size": 1, "type": "stone"},
	]})
	assert(not checked.has("error"), str(checked))
	var balance := base.duplicate(true)
	balance.world["blueprintBlocks"] = checked.blocks
	var state := State.new(balance)
	for resource_id in range(6):
		state._move(resource_id, State.Owner.UNMINED, State.Owner.PLACED)
	state.current_row = 1
	state.row_start = 6
	state.completed_rows = 1
	var production := Construction.new(state, balance)
	production._refresh_routes()
	var geometry = state.geometry
	var unit: Vector2 = geometry.brick_size()
	var left: float = balance.world.pyramidLeft
	var floor_y := geometry.stage_height(1)
	var high_y := 4.0 * unit.y
	var high_right := left + 9.0 * unit.x
	var target := Vector2(left + 16.75 * unit.x, high_y)
	var saw_work_height := false
	for scaffold: Dictionary in production._scaffolds:
		for section: Dictionary in scaffold.sections:
			if str(section.id).begins_with("run:"):
				assert(section.y + 0.00001 >= floor_y, str(section))
				if section.x0 >= high_right - 0.00001:
					assert(section.y <= high_y + 0.00001, str(section))
					saw_work_height = saw_work_height or is_equal_approx(section.y, floor_y)
	assert(saw_work_height, "Target needs a deck at its lower face")
	var saw_high_rise := false
	for scaffold: Dictionary in production._scaffolds:
		for transition: Dictionary in scaffold.transitions:
			if is_equal_approx(transition["to"].y, high_y):
				assert(transition["from"].x < left + 5.0 * unit.x)
				saw_high_rise = true
	assert(saw_high_rise)
	var entry := Vector2(left - 2.0 * unit.x, 0.0)
	var route_settings := {"include_surfaces": false}
	var outward := Routes.find_path(geometry, production._placed_snapshot,
		production._scaffolds, entry, target, route_settings)
	assert(outward.ok, str(outward))
	var after_ids: Array = state.stock(State.Owner.PLACED).duplicate()
	after_ids.append(6)
	var after := geometry.placed_surface_snapshot(after_ids)
	var back := Routes.find_path(geometry, after, production._scaffolds,
		target, entry, route_settings)
	assert(back.ok, str(back))


func _check_descent_to_raised_deck(base: Dictionary) -> void:
	_check_delivery_and_return(base, [
		{"x": 0, "y": 0, "size": 1},
		{"x": 1, "y": 0, "size": 1},
		{"x": 2, "y": 0, "size": 1},
		{"x": 3, "y": 0, "size": 1},
		{"x": 4, "y": 0, "size": 2},
		{"x": 6, "y": 0, "size": 1},
		{"x": 7, "y": 0, "size": 2},
		{"x": 9, "y": 0, "size": 2},
		{"x": 0, "y": 1, "size": 4},
		{"x": 4, "y": 2, "size": 2},
		{"x": 7, "y": 2, "size": 2},
	], 0, 1)


func _check_recess_and_overlapping_decks(base: Dictionary) -> void:
	_check_delivery_and_return(base, [
		{"x": 0, "y": 0, "size": 2},
		{"x": 2, "y": 0, "size": 2},
		{"x": 4, "y": 0, "size": 2},
		{"x": 6, "y": 0, "size": 1},
		{"x": 7, "y": 0, "size": 2},
		{"x": 9, "y": 0, "size": 1},
		{"x": 10, "y": 0, "size": 1},
		{"x": 11, "y": 0, "size": 1},
		{"x": 12, "y": 0, "size": 1},
		{"x": 13, "y": 0, "size": 2},
		{"x": 15, "y": 0, "size": 2},
		{"x": 17, "y": 0, "size": 2},
		{"x": 9, "y": 1, "size": 4},
		{"x": 0, "y": 2, "size": 2},
		{"x": 2, "y": 2, "size": 4},
		{"x": 7, "y": 2, "size": 2},
		{"x": 13, "y": 2, "size": 2},
		{"x": 15, "y": 2, "size": 2},
	], 2, 2)


func _check_delivery_and_return(base: Dictionary, blocks: Array, placed_in_row: int,
		expected_placements: int) -> void:
	var checked := Blueprint.validate({"version": 2, "blocks": blocks})
	assert(not checked.has("error"), str(checked))
	var balance := base.duplicate(true)
	balance.world["blueprintBlocks"] = checked.blocks
	var state := State.new(balance)
	state.current_row = 2
	state.completed_rows = 2
	state.row_start = state.geometry.placement_start_for_stage(state.current_row)
	for resource_id in range(state.row_start + placed_in_row):
		state._move(resource_id, State.Owner.UNMINED, State.Owner.PLACED)
	var first_id := state.placed_count()
	for block_id in range(first_id, first_id + expected_placements):
		state._move(block_id, State.Owner.UNMINED, State.Owner.FINISHED)
	var production := Construction.new(state, balance)
	var builder := state.worker(state.active_builder_id)
	builder.position = state.geometry.lift_operator_position()
	production.assign_tasks()
	assert(state.delivery_point.is_finite(), "The raised deck must keep the delivery route connected")
	var returns := 0
	for _tick in range(2000):
		for id in [builder.id, State.Owner.LIFT]:
			for event in state.worker(id).advance(0.1):
				production.apply_completion(event)
				if event.state == &"return_to_platform":
					returns += 1
		production.assign_tasks()
		if returns == expected_placements:
			break
	assert(returns == expected_placements, str(production.blocked_snapshot()))
	assert(state.placed_count() == first_id + expected_placements and state.validate().is_empty())
