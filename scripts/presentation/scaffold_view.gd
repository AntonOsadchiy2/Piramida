extends Node2D
## Retains the sections already drawn and appends only newly reached spans.

const FRAME := Color("#583b2b")
const WOOD := Color("#9f6c43")
const EDGE := Color("#c4915d")
const RAIL_HEIGHT := Vector2(0, -15)
const POST_SPACING := 108.0

class Floor:
	var y: float
	var anchor: float
	var left: float
	var right: float

	func _init(start: Vector2) -> void:
		y = start.y
		anchor = start.x
		left = start.x
		right = start.x

var _drawing := RenderingServer.canvas_item_create()
var _floors: Array[Floor] = []
var _path_index := 0
var _next_point := 1
var _support_surface: Callable


func _ready() -> void:
	RenderingServer.canvas_item_set_parent(_drawing, get_canvas_item())


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _drawing.is_valid():
		RenderingServer.free_rid(_drawing)


func replace_paths(paths: Array[PackedVector2Array], pixels_per_unit: float, support_surface: Callable) -> void:
	RenderingServer.canvas_item_clear(_drawing)
	_support_surface = support_surface
	var scale_to_screen := Vector2(pixels_per_unit, -pixels_per_unit)
	for path in paths:
		_floors.clear()
		for index in range(1, path.size()):
			_draw_span(path[index - 1] * scale_to_screen, path[index] * scale_to_screen)
		if not _floors.is_empty():
			_draw_post(_floors.size() - 1, path[-1].x * pixels_per_unit)


func append_paths(paths: Array[PackedVector2Array], pixels_per_unit: float) -> void:
	var scale_to_screen := Vector2(pixels_per_unit, -pixels_per_unit)
	while _path_index < paths.size():
		var path := paths[_path_index]
		for index in range(_next_point, path.size()):
			_draw_span(path[index - 1] * scale_to_screen, path[index] * scale_to_screen)
		_next_point = path.size()
		if _path_index + 1 == paths.size():
			break
		_path_index += 1
		_next_point = 1


func _draw_span(start: Vector2, finish: Vector2) -> void:
	if is_equal_approx(start.y, finish.y):
		_append_floor(start, finish)
	else:
		_draw_stairs(start, finish)


func _append_floor(start: Vector2, finish: Vector2) -> void:
	if _floors.is_empty() or not is_equal_approx(_floors[-1].y, start.y):
		_floors.append(Floor.new(start))
		_draw_post(_floors.size() - 1, start.x)
	var index := _floors.size() - 1
	_extend_floor(index, start.x)
	_extend_floor(index, finish.x)


func _extend_floor(index: int, x: float) -> void:
	var floor := _floors[index]
	var edge := clampf(x, floor.left, floor.right)
	if is_equal_approx(x, edge):
		return
	floor.left = minf(x, floor.left)
	floor.right = maxf(x, floor.right)

	# Reaching a new grid point adds a post without shifting the previous ones.
	var first := ceili((minf(edge, x) - floor.anchor) / POST_SPACING)
	var last := floori((maxf(edge, x) - floor.anchor) / POST_SPACING)
	for step in range(first, last + 1):
		var post_x := floor.anchor + float(step) * POST_SPACING
		if not is_equal_approx(post_x, edge):
			_draw_post(index, post_x)
	_draw_floor(Vector2(edge, floor.y), Vector2(x, floor.y))


func _draw_post(index: int, x: float) -> void:
	var foot := Vector2(x, _floors[index].y)
	var support_y := 0.0
	if _support_surface.is_valid():
		support_y = maxf(foot.y, _support_surface.call(x))
	elif index > 0 and _floors[index - 1].y < 0.0:
		# A lower deck may need one more section to carry an overhanging post.
		_extend_floor(index - 1, x)
		support_y = _floors[index - 1].y
	_line(foot + RAIL_HEIGHT, Vector2(x, support_y), FRAME, 3.0)


func _draw_floor(start: Vector2, finish: Vector2) -> void:
	_line(start + RAIL_HEIGHT, finish + RAIL_HEIGHT, WOOD, 2.5)
	_line(start + Vector2(0, 5), finish + Vector2(0, 5), FRAME, 9.0)
	_line(start + Vector2(0, 2), finish + Vector2(0, 2), WOOD, 4.0)
	_line(start, finish, EDGE, 1.5)


func _draw_stairs(start: Vector2, finish: Vector2) -> void:
	var bottom := start if start.y > finish.y else finish
	var top := finish if start.y > finish.y else start
	var steps := maxi(2, ceili((bottom.y - top.y) / 9.0))
	var offset := Vector2(0, 7)
	_line(bottom + offset, top + offset, FRAME, 5.0)
	_line(bottom + RAIL_HEIGHT, top + RAIL_HEIGHT, WOOD, 2.5)
	_line(bottom + RAIL_HEIGHT, bottom, FRAME, 3.0)
	_line(top + RAIL_HEIGHT, top, FRAME, 3.0)
	for index in range(steps):
		var low := bottom.lerp(top, float(index) / steps)
		var high := bottom.lerp(top, float(index + 1) / steps)
		var corner := Vector2(high.x, low.y)
		_line(low, corner, EDGE, 3.5)
		_line(corner, high, WOOD, 2.5)


func _line(from: Vector2, to: Vector2, color: Color, width: float) -> void:
	RenderingServer.canvas_item_add_line(_drawing, from, to, color, width, true)
