extends SceneTree

const Blueprint = preload("res://scripts/domain/blueprint.gd")
const State = preload("res://scripts/domain/game_state.gd")


func _initialize() -> void:
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	var checked := Blueprint.validate({"version": 2, "blocks": [
		{"x": 0, "y": 0, "size": 4, "type": "stone"},
		{"x": 4, "y": 0, "size": 2, "type": "stone"},
		{"x": 7, "y": 0, "size": 1, "type": "stone"},
	]})
	assert(not checked.has("error"))
	var balance := base.duplicate(true)
	balance.world["blueprintBlocks"] = checked.blocks
	var state := State.new(balance)
	var geometry = state.geometry
	var unit: Vector2 = geometry.brick_size()
	var left: float = balance.world.pyramidLeft
	var empty := state.placed_surface_snapshot()
	var slope: Dictionary = geometry.scaffold_snapshot(empty,
		Vector2(left - 0.7, 0.0), Vector2(left, unit.y))
	assert(slope.ok and slope.transitions[0].kind == "slope")
	_check_geometry(empty, slope)
	assert(geometry.scaffold_snapshot(empty, Vector2(left - 0.7, 0.0),
		Vector2(left, unit.y)) == slope)
	for id in range(3):
		state._move(id, State.Owner.UNMINED, State.Owner.PLACED)
	var placed := state.placed_surface_snapshot()
	for item in [
		{"x": left + 2.0 * unit.x, "y": 4.0 * unit.y},
		{"x": left + 5.0 * unit.x, "y": 2.0 * unit.y},
		{"x": left + 7.5 * unit.x, "y": unit.y},
	]:
		var work := Vector2(item.x, item.y)
		var section: Dictionary = geometry.scaffold_snapshot(placed,
			work, work,
			{"section_width": 1.5 * unit.x, "max_span": 2.0 * unit.x})
		assert(section.ok, str(section))
		_check_geometry(placed, section)
		assert(geometry.scaffold_snapshot(placed,
			work, work,
			{"section_width": 1.5 * unit.x, "max_span": 2.0 * unit.x}) == section)
	var gap: Dictionary = geometry.scaffold_snapshot(empty,
		Vector2(left - 0.7, 0.0), Vector2(left, 4.0 * unit.y),
		{"max_void_depth": unit.y, "max_void_width": 0.1 * unit.x})
	assert(not gap.ok and gap.reason == "void_limit", str(gap))
	var mixed_gap: Dictionary = geometry.scaffold_snapshot(placed,
		Vector2(left + 6.5 * unit.x, 2.0 * unit.y),
		Vector2(left + 6.5 * unit.x, 2.0 * unit.y),
		{"section_width": 1.5 * unit.x, "max_span": 2.0 * unit.x,
			"max_void_depth": unit.y, "max_void_width": 0.2 * unit.x})
	assert(not mixed_gap.ok and mixed_gap.reason == "void_limit", str(mixed_gap))
	var unsupported: Dictionary = geometry.scaffold_snapshot(empty,
		Vector2(left - 0.7, 0.0), Vector2(left, 4.0 * unit.y),
		{"max_post_height": unit.y})
	assert(not unsupported.ok and unsupported.reason == "post_without_support", str(unsupported))
	var blocked: Dictionary = geometry.scaffold_snapshot(placed,
		Vector2(left - unit.x, 0.0), Vector2(left + 2.0 * unit.x, 0.0))
	assert(not blocked.ok and blocked.reason != "", str(blocked))
	print("PASS: scaffold sections, supports, transitions and limits")
	quit()


func _check_geometry(placed: Dictionary, scaffold: Dictionary) -> void:
	assert(scaffold.sections.size() == 1 and scaffold.posts.size() == 2)
	for post: Dictionary in scaffold.posts:
		var support: Dictionary = {}
		for surface: Dictionary in placed.surfaces:
			if surface.id == post.support_id:
				support = surface
				break
		assert(not support.is_empty())
		assert(is_equal_approx(post.y0, support.y))
		assert(support.x0 <= post.x0 and support.x1 >= post.x1)
		for block: Dictionary in placed.blocks:
			assert(not (block.x0 < post.x1 and block.x1 > post.x0
				and block.y0 < post.y1 and block.y1 > post.y0))
