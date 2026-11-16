extends Camera2D

enum Focus { FREE, OVERVIEW, QUARRY, CONSTRUCTION }

const MIN_ZOOM := 0.8
const MAX_ZOOM := 2.0
const DRAG_THRESHOLD := 8.0
const MOUSE := -1

@onready var world = get_parent()
@onready var hud: Control = get_node_or_null("../../HUD/Control")

var _bounds: Rect2
var _quarry: Rect2
var _construction: Rect2
var _base_zoom := 1.0
var _relative_zoom := 1.0
var _focus := Focus.FREE
var _points: Dictionary[int, Vector2] = {}
var _origin: Vector2
var _dragged := false


func _ready() -> void:
	get_viewport().size_changed.connect(_resize)
	if hud == null:
		set_process_input(false)
		return
	$"../../HUD/Control/CameraButtons/Overview".pressed.connect(show_overview)
	$"../../HUD/Control/CameraButtons/Quarry".pressed.connect(show_quarry)
	$"../../HUD/Control/CameraButtons/Construction".pressed.connect(show_construction)


func setup(bounds: Rect2, quarry: Rect2, construction: Rect2) -> void:
	_bounds = bounds
	_quarry = quarry
	_construction = construction
	show_overview()


func show_overview() -> void:
	_set_focus(Focus.OVERVIEW)


func show_quarry() -> void:
	_set_focus(Focus.QUARRY)


func show_construction() -> void:
	_set_focus(Focus.CONSTRUCTION)


func _set_focus(focus: Focus) -> void:
	if not _bounds.has_area():
		return
	_points.clear()
	_focus = focus
	_resize()


func _resize() -> void:
	if not _bounds.has_area():
		return
	_points.clear()
	var size := get_viewport_rect().size
	_base_zoom = _fit(size, _bounds)
	if _focus != Focus.FREE:
		var target := _bounds
		if _focus == Focus.QUARRY:
			target = _quarry
		elif _focus == Focus.CONSTRUCTION:
			target = _construction
		position = target.get_center()
		_relative_zoom = clampf(_fit(size, target) / _base_zoom, MIN_ZOOM, MAX_ZOOM)
	_apply_view()


func _fit(size: Vector2, rect: Rect2) -> float:
	return minf(size.x / rect.size.x, size.y / rect.size.y)


func _apply_view() -> void:
	zoom = Vector2.ONE * (_base_zoom * _relative_zoom)
	var half := get_viewport_rect().size / (2.0 * zoom.x)
	if hud == null:
		# Keep the surface at the original height in the wallpaper panorama.
		position.y = -half.y * 0.58
		force_update_scroll()
		return
	var travel := (_bounds.size * 0.5 - half).max(Vector2.ZERO)
	var center := _bounds.get_center()
	position = position.clamp(center - travel, center + travel)
	force_update_scroll()


func _input(event: InputEvent) -> void:
	if not _bounds.has_area() or event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			if not _points.has(MOUSE) and _points.size() < 2:
				_begin(event.index, event.position)
		elif _points.has(event.index):
			_end(event.index, event.position, event.canceled)
	elif event is InputEventScreenDrag and _points.has(event.index):
		_move(event.index, event.position)
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and _points.is_empty():
				_begin(MOUSE, event.position)
			elif not event.pressed and _points.has(MOUSE):
				_end(MOUSE, event.position, event.canceled)
		elif event.pressed and _points.is_empty() and not _over_ui(hud, event.position):
			if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
				var factor := 1.15 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15
				_transform_view(event.position, event.position, factor)
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _points.has(MOUSE):
		_move(MOUSE, event.position)


func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED]:
		_points.clear()


func _over_ui(node: Control, point: Vector2) -> bool:
	if not node.is_visible_in_tree():
		return false
	var inside := Rect2(Vector2.ZERO, node.size).has_point(
		node.get_global_transform_with_canvas().affine_inverse() * point)
	if inside and node.mouse_filter != Control.MOUSE_FILTER_IGNORE:
		return true
	if node.clip_contents and not inside:
		return false
	for child in node.get_children():
		if child is Control and _over_ui(child, point):
			return true
	return false


func _begin(id: int, point: Vector2) -> void:
	if _over_ui(hud, point):
		return
	if _points.is_empty():
		_origin = point
		_dragged = false
	else:
		_dragged = true
	_points[id] = point
	get_viewport().set_input_as_handled()


func _move(id: int, point: Vector2) -> void:
	var previous := _points[id]
	_points[id] = point
	if _points.size() == 2:
		var ids := _points.keys()
		var other := _points[ids[1] if ids[0] == id else ids[0]]
		var distance := previous.distance_to(other)
		var factor := point.distance_to(other) / distance if distance > 1.0 else 1.0
		_transform_view((previous + other) * 0.5, (point + other) * 0.5, factor)
	elif _dragged:
		_transform_view(previous, point, 1.0)
	elif point.distance_to(_origin) >= DRAG_THRESHOLD:
		_dragged = true
		_transform_view(_origin, point, 1.0)
	get_viewport().set_input_as_handled()


func _end(id: int, point: Vector2, canceled: bool) -> void:
	_points.erase(id)
	if not canceled and not _dragged and point.distance_to(_origin) < DRAG_THRESHOLD \
		and not _over_ui(hud, point):
		world.select_worker_at(point)
	get_viewport().set_input_as_handled()


func _transform_view(from: Vector2, to: Vector2, factor: float) -> void:
	_focus = Focus.FREE
	var center := get_viewport_rect().size * 0.5
	var anchor := position + (from - center) / zoom.x
	_relative_zoom = clampf(_relative_zoom * factor, MIN_ZOOM, MAX_ZOOM)
	position = anchor - (to - center) / (_base_zoom * _relative_zoom)
	_apply_view()
