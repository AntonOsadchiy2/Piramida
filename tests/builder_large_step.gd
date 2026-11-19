extends SceneTree

const Blueprint = preload("res://scripts/domain/blueprint.gd")
const State = preload("res://scripts/domain/game_state.gd")
const Construction = preload("res://scripts/simulation/construction_production.gd")
const Routes = preload("res://scripts/domain/placed_route.gd")

func _initialize() -> void:
	var balance: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	var checked := Blueprint.validate({"version": 2, "blocks": [
		{"x": 24, "y": 0, "size": 1, "type": "stone"},
		{"x": 22, "y": 2, "size": 2, "type": "stone"},
		{"x": 25, "y": 2, "size": 4, "type": "stone"},
		{"x": 29, "y": 2, "size": 4, "type": "stone"},
	]})
	assert(not checked.has("error"))
	balance.world.blueprintBlocks = checked.blocks
	balance.world.pyramidRows = 2
	var state := State.new(balance)
	for id in range(3):
		state._move(id, State.Owner.UNMINED, State.Owner.PLACED)
	state.current_row = 1
	state.row_start = 1
	state.completed_rows = 1
	var builder = state.worker(state.active_builder_id)
	builder.position = Vector2(17.4, 1.12)
	var production := Construction.new(state, balance)
	production._refresh_routes()
	var target := Vector2(18.72, 1.68)
	var path := Routes.find_path(state.geometry, production._placed_snapshot,
		production._scaffolds, builder.position, target)
	assert(path.ok, "Builder cannot cross the large-block step: %s %s" % [path.reason, production._scaffolds])
	assert(production._choose_delivery_point().is_finite(),
		"No delivery near work point %s" % production._placement_point())
	state.delivery_point = Vector2.INF
	var restored := Construction.new(state, balance)
	assert(restored.restore_routes({}))
	assert(not state.delivery_point.is_finite())
	restored.assign_tasks()
	assert(state.delivery_point.is_finite(), "Builder did not recalculate delivery after restore")
	_check_wide_high_deck(balance)
	print("PASS: builder crosses large-block step and resumes delivery")
	quit()


func _check_wide_high_deck(base: Dictionary) -> void:
	var blocks: Array = []
	for x in range(0, 18, 2):
		blocks.append({"x": x, "y": 0, "size": 2, "type": "stone"})
	for x in range(18, 22):
		blocks.append({"x": x, "y": 0, "size": 1, "type": "stone"})
	for x in range(22, 36, 2):
		blocks.append({"x": x, "y": 0, "size": 2, "type": "stone"})
	for x in range(36, 40):
		blocks.append({"x": x, "y": 0, "size": 1, "type": "stone"})
	for x in range(40, 58, 2):
		blocks.append({"x": x, "y": 0, "size": 2, "type": "stone"})
	blocks.append({"x": 18, "y": 1, "size": 4, "type": "stone"})
	blocks.append({"x": 36, "y": 1, "size": 4, "type": "stone"})
	var checked := Blueprint.validate({"version": 2, "blocks": blocks})
	assert(not checked.has("error"), str(checked))
	var balance := base.duplicate(true)
	balance.world.blueprintBlocks = checked.blocks
	var state := State.new(balance)
	var row_start := state.geometry.row_size(0)
	for id in range(row_start + 1):
		state._move(id, State.Owner.UNMINED, State.Owner.PLACED)
	state.current_row = 1
	state.row_start = row_start
	state.completed_rows = 1
	var production := Construction.new(state, balance)
	production._refresh_routes()
	var placed := state.placed_surface_snapshot()
	var top_block: Dictionary = placed.blocks.filter(func(block: Dictionary) -> bool:
		return int(block.id) == row_start)[0]
	var unit := state.geometry.brick_size()
	var direct_run := state.geometry.scaffold_run_snapshot(placed,
		Vector2(top_block.x0, top_block.y1), Vector2(top_block.x1, top_block.y1),
		{"max_span": 2.0 * unit.x, "max_void_width": 2.0 * unit.x,
			"max_void_depth": 5.0 * unit.y, "max_post_height": 5.0 * unit.y})
	assert(direct_run.ok, "Top-block run rejected: %s left=%s right=%s surfaces=%s" % [
		direct_run,
		state.geometry.support_below(placed, Vector2(top_block.x0 + 0.1 * unit.x, top_block.y1)),
		state.geometry.support_below(placed, Vector2(top_block.x1 - 0.1 * unit.x, top_block.y1)),
		placed.surfaces.filter(func(surface: Dictionary) -> bool:
			return is_equal_approx(float(surface.y), float(top_block.y1)))])
	var work := production._placement_point()
	var delivery := production._choose_delivery_point()
	assert(work.is_finite(), "Wide high deck has no safe work point: %s" % [production._scaffolds])
	assert(delivery.is_finite(), "Wide high deck has no delivery point: work=%s scaffolds=%s" % [
		work, production._scaffolds])
	var visible_posts := 0
	for scaffold: Dictionary in production._scaffolds:
		for post: Dictionary in scaffold.posts:
			if float(post.y1) - float(post.y0) > 0.00001:
				visible_posts += 1
	assert(visible_posts > 0 and visible_posts <= placed.blocks.size(),
		"Wide high deck has excessive posts: %d" % visible_posts)
