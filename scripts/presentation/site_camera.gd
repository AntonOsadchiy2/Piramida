extends Camera2D

signal view_changed

const Geometry = preload("res://scripts/domain/world_geometry.gd")
const ZOOM_STEP := 1.09
const DETAIL_BLOCK_SIZE := 4.0
const IDLE_SECONDS := 10.0
const RETURN_SECONDS := 1.5
# Screen proportions of the desktop reference.
const OVERVIEW_GROUND_Y := 0.784
const OVERVIEW_PYRAMID_RIGHT := 0.965
const OVERVIEW_PYRAMID_WIDTH := 0.41
const OVERVIEW_WORKSHOP_TO_RIGHT := 0.565
const OVERVIEW_REFERENCE_ASPECT := 1.85
const EDGE_PAN_SPEED := 0.4
const EDGE_PAN_TIMEOUT := 0.04

var overview: Rect2
var pan_bounds: Rect2
var _quarry_bounds: Rect2
var _bounds: Rect2
var _pyramid_span: Vector2
var _workshop_x: float
var _detail_size: Vector2
var _overview_zoom := 1.0
var _max_zoom := 1.0
var _edge_direction := Vector2.ZERO
var _edge_time_left := 0.0
var _idle_elapsed := 0.0
var _return_from := Vector2.ZERO
var _return_from_zoom := 1.0


func _ready() -> void:
	get_viewport().size_changed.connect(_resize)


func setup(bounds: Rect2, cell_size: Vector2, pyramid_span: Vector2,
		workshop_x: float, quarry_bounds: Rect2) -> void:
	_bounds = bounds
	_quarry_bounds = quarry_bounds
	_detail_size = cell_size * DETAIL_BLOCK_SIZE
	_pyramid_span = pyramid_span
	_workshop_x = workshop_x
	set_process(false)
	_resize()


func _resize() -> void:
	var size := get_viewport_rect().size
	if not _bounds.has_area() or size.x <= 0.0 or size.y <= 0.0:
		return
	var zoom_ratio := zoom.x / _overview_zoom
	var framing_width := minf(size.x, size.y * OVERVIEW_REFERENCE_ASPECT)
	var pyramid_zoom := framing_width * OVERVIEW_PYRAMID_WIDTH / (_pyramid_span.y - _pyramid_span.x)
	var workshop_zoom := framing_width * OVERVIEW_WORKSHOP_TO_RIGHT / (_pyramid_span.y - _workshop_x)
	_overview_zoom = minf(pyramid_zoom, workshop_zoom) * 1.2
	var detail_zoom := size / _detail_size
	_max_zoom = maxf(_overview_zoom, minf(detail_zoom.x, detail_zoom.y))
	# In world coordinates the main ground is at y = 0.
	var world_size := size / _overview_zoom
	var origin := Vector2(_pyramid_span.y, 0.0) \
		- world_size * Vector2(OVERVIEW_PYRAMID_RIGHT, OVERVIEW_GROUND_Y)
	overview = Rect2(origin, world_size)

	# Keep the full construction site and quarry reachable when panning.
	var panorama_size := size / Geometry.overview_zoom(_bounds, size)
	var panorama_origin := Vector2(_bounds.get_center().x, 0.0) \
		- panorama_size * Vector2(0.5, 1.0 - Geometry.OVERVIEW_GROUND_FROM_BOTTOM)
	pan_bounds = overview.merge(Rect2(panorama_origin, panorama_size))
	if _quarry_bounds.has_area():
		pan_bounds = pan_bounds.merge(_quarry_bounds)
	_edge_time_left = 0.0
	if not is_processing():
		_apply_view(overview.get_center(), _overview_zoom)
		return
	_apply_view(position, clampf(_overview_zoom * zoom_ratio, _overview_zoom, _max_zoom))
	_restart_idle_timer()


func _restart_idle_timer() -> void:
	_idle_elapsed = 0.0
	set_process(true)


func _process(delta: float) -> void:
	if not is_current() or not overview.has_area():
		return
	if _edge_time_left > 0.0:
		var duration := minf(delta, _edge_time_left)
		_edge_time_left -= duration
		var distance := get_viewport_rect().size * EDGE_PAN_SPEED * duration / zoom
		_apply_view(position + _edge_direction * distance, zoom.x)
		return
	if _idle_elapsed < IDLE_SECONDS:
		_idle_elapsed += delta
		if _idle_elapsed < IDLE_SECONDS:
			return
		_return_from = position
		_return_from_zoom = zoom.x
	else:
		_idle_elapsed += delta
	var progress := smoothstep(0.0, RETURN_SECONDS, _idle_elapsed - IDLE_SECONDS)
	if progress >= 1.0:
		_apply_view(overview.get_center(), _overview_zoom)
		set_process(false)
		return
	var next_zoom := _return_from_zoom * pow(_overview_zoom / _return_from_zoom, progress)
	_apply_view(_return_from.lerp(overview.get_center(), progress), next_zoom)


func _input(event: InputEvent) -> void:
	if not is_current() or not overview.has_area():
		return
	if event is InputEventMouseButton:
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_restart_idle_timer()
			var steps: float = event.factor if event.factor > 0.0 else 1.0
			if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				steps = -steps
			var next_zoom := clampf(zoom.x * pow(ZOOM_STEP, steps),
				_overview_zoom, _max_zoom)
			if not is_equal_approx(next_zoom, zoom.x):
				var offset: Vector2 = event.position - get_viewport_rect().size * 0.5
				_apply_view(position + offset * (1.0 / zoom.x - 1.0 / next_zoom), next_zoom)
	elif event is InputEventMouseMotion:
		var size := get_viewport_rect().size
		var point: Vector2 = event.position
		var direction := Vector2(int(point.x >= size.x) - int(point.x < 0.0),
			int(point.y >= size.y) - int(point.y < 0.0))
		if direction != Vector2.ZERO:
			_edge_direction = direction.normalized()
			_edge_time_left = EDGE_PAN_TIMEOUT
			_restart_idle_timer()


func _apply_view(center: Vector2, scale_factor: float) -> void:
	zoom = Vector2.ONE * scale_factor
	if scale_factor <= _overview_zoom:
		position = overview.get_center()
	else:
		var half_size := get_viewport_rect().size / zoom * 0.5
		position = center.clamp(pan_bounds.position + half_size, pan_bounds.end - half_size)
	force_update_scroll()
	view_changed.emit()
