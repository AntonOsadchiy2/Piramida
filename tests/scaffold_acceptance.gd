extends SceneTree

const Blueprint = preload("res://scripts/domain/blueprint.gd")
const Geometry = preload("res://scripts/domain/world_geometry.gd")
const Road = preload("res://scripts/domain/scaffold_road.gd")
const ScaffoldView = preload("res://scripts/presentation/scaffold_view.gd")


func _initialize() -> void:
	var balance: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	var blueprint := Blueprint.validate({"version": 2, "blocks": [
		{"x": 0, "y": 3},
		{"x": 4, "y": 3, "size": 4},
		{"x": 58, "y": 3},
		{"x": 0, "y": 4},
		{"x": 3, "y": 4},
		{"x": 5, "y": 7},
		{"x": 5, "y": 10, "size": 2},
	]})
	assert(not blueprint.has("error"))
	balance.world.blueprintBlocks = blueprint.blocks
	var geometry := Geometry.new(balance)
	var road := Road.new()
	var unit := geometry.brick_size()

	road.extend(geometry, 0, 0, 0)
	var first := road.tip()
	var entry := road.paths[0][0]
	assert(entry.y == 0.0 and is_equal_approx(first.y, 5.0 * unit.y))
	assert(road.route(entry, first) == road.paths[0])
	var prefix := road.paths[0]
	assert(prefix.size() == 6 and prefix[2].x > prefix[1].x and prefix[4].x < prefix[3].x)
	_check_stairs(prefix)
	road.extend(geometry, 0, 0, 1)
	var large := road.tip()
	assert(road.paths[0].slice(0, prefix.size()) == prefix)
	assert(large.is_equal_approx(geometry.brick_origin(0, 1) + Vector2(2.0 * unit.x, 2.0 * unit.y)))
	assert(road.route(first, large) == PackedVector2Array([first, large]))

	road.extend(geometry, 0, 0, 2)
	var far := road.tip()
	var completed := road.paths[0]
	road.extend(geometry, 0, 0, 3)
	assert(road.tip() == far and road.paths[0] == completed)
	road.extend(geometry, 1, 3, 3)
	assert(road.paths.size() == 1 and road.tip() == first and road.paths[0][-1] == first)
	assert(road.route(far, first) == PackedVector2Array([far, first]))
	road.extend(geometry, 1, 3, 4)
	var previous_entry := road.row_entry()
	var shared_floor := road.paths[0]
	road.extend(geometry, 2, 5, 5)
	var climb := road.route(far, road.tip())
	assert(road.paths[0] == shared_floor and road.paths[1][0] == previous_entry)
	assert(climb.has(previous_entry) and climb[0] == far and climb[-1] == road.tip())
	assert(is_equal_approx(road.tip().y, 9.0 * unit.y))
	var descent := road.route(road.tip(), far)
	descent.reverse()
	assert(descent == climb)

	road.extend(geometry, 3, 6, 6)
	assert(road.paths.size() == 3 and is_equal_approx(road.tip().y, 12.0 * unit.y))
	_check_stairs(road.paths[1])
	_check_stairs(road.paths[2])
	var rebuilt := Road.new()
	rebuilt.extend(geometry, 3, 6, 7)
	assert(rebuilt.paths == road.paths)
	var ground := Vector2(entry.x - 2.0, 0.0)
	var route := rebuilt.route(ground, rebuilt.tip())
	assert(route[0] == ground and route[1] == entry and route[-1] == rebuilt.tip())
	assert(not route.has(far))
	_check_support_extension()
	print("PASS: scaffold floors grow by block with fixed posts and support from the deck below")
	quit()


func _check_stairs(path: PackedVector2Array) -> void:
	assert(is_equal_approx(path[0].y, path[1].y))
	assert(is_equal_approx(path[-1].y, path[-2].y))
	for index in range(1, path.size()):
		if path[index].y > path[index - 1].y:
			assert(index + 1 < path.size() and is_equal_approx(path[index + 1].y, path[index].y))


func _check_support_extension() -> void:
	var view := ScaffoldView.new()
	var paths: Array[PackedVector2Array] = [
		PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(20, 60), Vector2(90, 60)]),
	]
	view.append_paths(paths, 1.0)
	var lower := view._floors[1]
	var ground := view._floors[0]
	paths[0].append(Vector2(250, 60))
	view.append_paths(paths, 1.0)
	assert(view._floors[1] == lower and lower.anchor == 20 and lower.left == 20 and lower.right == 250)
	assert(ground.y == 0.0 and ground.right == 10.0)
	paths.append(PackedVector2Array([Vector2(90, 60), Vector2(300, 120), Vector2(430, 120)]))
	view.append_paths(paths, 1.0)
	var upper := view._floors[2]
	assert(lower.y == -60 and upper.y == -120 and lower.right == upper.anchor + ScaffoldView.POST_SPACING)
	view.append_paths(paths, 1.0)
	assert(view._floors.size() == 3 and lower.anchor == 20 and upper.anchor == 300)
	view.free()
