extends SceneTree

const Blueprint = preload("res://scripts/domain/blueprint.gd")
const State = preload("res://scripts/domain/game_state.gd")
const Routes = preload("res://scripts/domain/placed_route.gd")


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
	var start := Vector2(left - unit.x, 0.0)
	var finish := Vector2(left + 5.0 * unit.x, 0.0)
	var empty := state.placed_surface_snapshot()
	var direct: Dictionary = Routes.find_path(geometry, empty, [], start, finish)
	assert(direct.ok and direct.edges.size() > 0, str(direct))
	assert(Routes.find_path(geometry, empty, [], start, finish) == direct)
	var old_section: Dictionary = geometry.scaffold_snapshot(empty,
		Vector2(left - 0.7 * unit.x, 0.0),
		Vector2(left + 0.2 * unit.x, unit.y),
		{"section_width": 1.5 * unit.x, "max_span": 2.0 * unit.x})
	assert(old_section.ok)
	state._move(0, State.Owner.UNMINED, State.Owner.PLACED)
	var placed := state.placed_surface_snapshot()
	var half_width := 0.09 * unit.x
	var edge := left - half_width
	assert(not geometry._scaffold_clear_segment(placed,
		Vector2(edge - 0.002 * unit.x, unit.y),
		Vector2(edge + 0.002 * unit.x, unit.y),
		0.18 * unit.x, 0.9 * unit.y, 0.02 * unit.y),
		"A narrow corner crossing must be detected between samples")
	var blocked: Dictionary = Routes.find_path(geometry, placed, [], start, finish)
	assert(not blocked.ok and blocked.reason == "disconnected", str(blocked))
	var stale: Dictionary = Routes.find_path(geometry, placed,
		[old_section], start, finish)
	assert(not stale.ok and stale.reason == "disconnected", str(stale))
	# Two stage-2 sections connect ground to the large block's exposed top.
	var settings := {"section_width": 1.5 * unit.x, "max_span": 2.0 * unit.x}
	var left_section: Dictionary = geometry.scaffold_snapshot(placed,
		Vector2(left - 0.7 * unit.x, 0.0),
		Vector2(left + 0.2 * unit.x, 4.0 * unit.y), settings)
	var right_section: Dictionary = geometry.scaffold_snapshot(placed,
		Vector2(left + 4.7 * unit.x, 0.0),
		Vector2(left + 3.8 * unit.x, 4.0 * unit.y), settings)
	assert(left_section.ok and right_section.ok, str([left_section, right_section]))
	var over: Dictionary = Routes.find_path(geometry, placed,
		[left_section, right_section], start, finish)
	assert(over.ok and over.length > direct.length, str(over))
	assert(over.edges.has(left_section.transitions[0].id))
	assert(over.edges.has(right_section.transitions[0].id))
	_check_segments(geometry, placed, over)
	var back: Dictionary = Routes.find_path(geometry, placed,
		[left_section, right_section], finish, start)
	assert(back.ok and is_equal_approx(back.length, over.length), str(back))
	_check_segments(geometry, placed, back)
	# A missing descent cannot be replaced with a direct line through masonry.
	var no_descent: Dictionary = Routes.find_path(geometry, placed,
		[left_section], start, finish)
	assert(not no_descent.ok and no_descent.reason == "disconnected", str(no_descent))
	# A step with no transition remains disconnected even when both endpoints have support.
	var top := Vector2(left + 2.0 * unit.x, 4.0 * unit.y)
	var no_step: Dictionary = Routes.find_path(geometry, placed, [], start, top)
	assert(not no_step.ok and no_step.reason == "disconnected", str(no_step))
	var with_step: Dictionary = Routes.find_path(geometry, placed,
		[left_section], start, top)
	assert(with_step.ok, str(with_step))
	for item in [{"id": 1, "x": 4.0, "size": 2.0},
			{"id": 2, "x": 7.0, "size": 1.0}]:
		var single := State.new(balance)
		single._move(item.id, State.Owner.UNMINED, State.Owner.PLACED)
		var shape := single.placed_surface_snapshot()
		var x0: float = left + item.x * unit.x
		var x1: float = x0 + item.size * unit.x
		var across: Dictionary = Routes.find_path(geometry, shape, [],
			Vector2(x0 - unit.x, 0.0), Vector2(x1 + unit.x, 0.0))
		assert(not across.ok and across.reason == "disconnected", str(across))
		var along: Dictionary = Routes.find_path(geometry, shape, [],
			Vector2(x0 + 0.2 * unit.x, item.size * unit.y),
			Vector2(x1 - 0.2 * unit.x, item.size * unit.y))
		assert(along.ok and along.edges.size() > 0, str(along))
	print("PASS: placed routes outward, return, block detour, gaps and steps")
	quit()


func _check_segments(geometry, placed: Dictionary, path: Dictionary) -> void:
	for i in range(1, path.points.size()):
		assert(geometry._scaffold_clear_segment(placed,
			path.points[i - 1], path.points[i],
			0.18 * geometry.brick_size().x,
			0.9 * geometry.brick_size().y,
			0.02 * geometry.brick_size().y))
