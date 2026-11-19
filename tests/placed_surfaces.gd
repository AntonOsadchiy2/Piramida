extends SceneTree

const Blueprint = preload("res://scripts/domain/blueprint.gd")
const State = preload("res://scripts/domain/game_state.gd")


func _initialize() -> void:
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	_check_standard(base)
	_check_custom(base)
	print("PASS: placed surfaces and nearest supports")
	quit()


func _check_standard(base: Dictionary) -> void:
	var state := State.new(base)
	var geometry = state.geometry
	var empty := state.placed_surface_snapshot()
	assert(empty.blocks.is_empty() and empty.surfaces.size() == 1)
	assert(geometry.support_below(empty, Vector2(10.0, 1.0)).source == "ground")
	assert(geometry.support_below(empty, Vector2(10.0, -0.1)).is_empty())
	state._move(0, State.Owner.UNMINED, State.Owner.PLACED)
	var snapshot := state.placed_surface_snapshot()
	var origin: Vector2 = geometry.brick_origin(0, 0)
	var top: Dictionary = geometry.support_below(snapshot,
		origin + Vector2(geometry.brick_size().x * 0.5, 1.0))
	assert(top.source_id == 0 and is_equal_approx(top.y, geometry.brick_size().y))
	assert(geometry.support_below(snapshot, origin + Vector2(0.1, 0.1)).is_empty())
	assert(geometry.support_below(snapshot, origin + Vector2(-0.1, 1.0)).source == "ground")


func _check_custom(base: Dictionary) -> void:
	var checked := Blueprint.validate({"version": 2, "blocks": [
		{"x": 0, "y": 0, "size": 4, "type": "stone"},
		{"x": 4, "y": 0, "size": 2, "type": "stone"},
		{"x": 7, "y": 0, "size": 1, "type": "stone"},
		{"x": 1, "y": 4, "size": 2, "type": "stone"},
		{"x": 3, "y": 4, "size": 1, "type": "stone"},
		{"x": 7, "y": 6, "size": 1, "type": "stone"},
	]})
	assert(not checked.has("error"))
	var balance := base.duplicate(true)
	balance.world["blueprintBlocks"] = checked.blocks
	var state := State.new(balance)
	var geometry = state.geometry
	var width: float = geometry.brick_size().x
	var height: float = geometry.brick_size().y
	var left: float = balance.world.pyramidLeft
	for id in [0, 1, 2, 3, 4]:
		state._move(id, State.Owner.UNMINED, State.Owner.PLACED)
	var snapshot := state.placed_surface_snapshot()
	assert(snapshot.blocks.size() == 5)
	assert(snapshot.blocks[0].x0 == left and is_equal_approx(snapshot.blocks[0].y1, 4.0 * height))
	assert(is_equal_approx(snapshot.blocks[1].x1, left + 6.0 * width))
	assert(is_equal_approx(snapshot.blocks[3].y1, 6.0 * height))
	var first_top := _surface(snapshot, 0, 4.0 * height)
	assert(is_equal_approx(first_top.x0, left))
	assert(is_equal_approx(first_top.x1, left + width))
	assert(_surface(snapshot, 3, 6.0 * height).source_id == 3)
	assert(_surface(snapshot, 4, 5.0 * height).source_id == 4)
	assert(geometry.support_below(snapshot, Vector2(left + 2.0 * width, 8.0 * height)).source_id == 3)
	assert(geometry.support_below(snapshot, Vector2(left + 3.5 * width, 8.0 * height)).source_id == 4)
	assert(geometry.support_below(snapshot, Vector2(left + 4.0 * width, 3.0 * height)).source_id == 1)
	assert(geometry.support_below(snapshot, Vector2(left + 6.5 * width, 8.0 * height)).source == "ground")
	assert(geometry.support_below(snapshot, Vector2(left + 7.5 * width, 8.0 * height)).source_id == 2)
	assert(geometry.support_below(snapshot, Vector2(left + 2.0 * width, 5.0 * height)).is_empty())
	var before := snapshot.duplicate(true)
	state._move(5, State.Owner.UNMINED, State.Owner.PLACED)
	var after := state.placed_surface_snapshot()
	assert(before.blocks.size() == 5 and after.blocks.size() == 6)
	assert(geometry.support_below(after, Vector2(left + 7.5 * width, 8.0 * height)).source_id == 5)
	var reordered := geometry.placed_surface_snapshot([4, 2, 0, 3, 1, 1])
	assert(reordered == before)


func _surface(snapshot: Dictionary, source_id: int, y: float) -> Dictionary:
	for surface: Dictionary in snapshot.surfaces:
		if surface.source_id == source_id and is_equal_approx(surface.y, y):
			return surface
	return {}
