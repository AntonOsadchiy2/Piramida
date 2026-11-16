extends Node2D

const Walk = preload("res://scripts/presentation/worker_walk.gd")
const CLOTHES := preload("res://scripts/presentation/overseer_clothes.gdshader")
const PACE := 155.0
const WATCH_SECONDS := 2.8
const ORDER_SECONDS := 1.8
const SCALE := 1.42
const ORDERS := ["Берегите откос!", "Ровнее грани!", "Следите за рядом!"]

# An optional presentation action can supply a global point to reach for at a stop.
var stop_action: Callable
var planted_stance := false

var _stops: PackedVector2Array
var _workers: Array[Node2D]
var _arrivals := PackedFloat64Array()
var _walked := PackedFloat64Array()
var _walker: Walk
var _order: Label


func setup(stops: PackedVector2Array, workers: Array[Node2D], show_orders: bool,
		cover_idle_shoulder := false) -> void:
	_stops = stops
	_workers = workers
	_arrivals.append(0.0)
	_walked.append(0.0)
	for index in range(stops.size()):
		var distance := stops[index].distance_to(stops[(index + 1) % stops.size()])
		_arrivals.append(_arrivals[-1] + WATCH_SECONDS + ORDER_SECONDS + distance / PACE)
		_walked.append(_walked[-1] + distance)
	_walker = Walk.new()
	_walker.planted_stance = planted_stance
	_walker.cover_idle_shoulder = cover_idle_shoulder
	_walker.scale = Vector2.ONE * SCALE
	var clothes := ShaderMaterial.new()
	clothes.shader = CLOTHES
	_walker.material = clothes
	add_child(_walker)
	if show_orders:
		_order = Label.new()
		_order.z_index = 1
		_order.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_order.add_theme_font_size_override("font_size", 46)
		_order.add_theme_color_override("font_color", Color("#fff1d4"))
		var background := StyleBoxFlat.new()
		background.bg_color = Color(0.18, 0.09, 0.10, 0.92)
		background.set_corner_radius_all(12)
		background.content_margin_left = 15
		background.content_margin_right = 15
		background.content_margin_top = 4
		background.content_margin_bottom = 4
		_order.add_theme_stylebox_override("normal", background)
		add_child(_order)
		_order.hide()


func render(seconds: float, finished: bool) -> void:
	var time := fposmod(seconds, _arrivals[-1])
	var index := _stops.size() - 1
	while time < _arrivals[index]:
		index -= 1
	var local_time := time - _arrivals[index]
	var wait := WATCH_SECONDS + ORDER_SECONDS
	var start := _stops[index]
	if _order != null:
		_order.hide()
	if local_time < wait:
		position = start
		var target := to_local(_workers[index].global_position) + Vector2(0, -90)
		var order_time := local_time - WATCH_SECONDS
		var reach := Vector2.INF
		if stop_action.is_valid() and not finished:
			reach = stop_action.call(index, order_time)
		var gesture := 0.0
		if order_time >= 0.0 and not finished:
			gesture = smoothstep(0.0, 0.24, order_time) * (1.0 - smoothstep(1.35, ORDER_SECONDS, order_time))
			if _order != null:
				_show_order(index, gesture)
		if reach.is_finite():
			target = to_local(reach) - Vector2(0, -90)
		var facing := -1.0 if target.x < 0.0 else 1.0
		var aim := clampf(Vector2(absf(target.x), target.y).angle(), -0.65, 0.45)
		_walker.pose_idle(seconds, facing, gesture, aim)
		return

	var next := _stops[(index + 1) % _stops.size()]
	var direction := start.direction_to(next)
	var distance := (local_time - wait) * PACE
	position = start + direction * distance
	if finished:
		_walker.pose_idle(seconds, direction.x)
	else:
		var stride := Walk.STEP_LENGTH * SCALE
		var stride_weight := 1.0
		if planted_stance:
			var remaining := start.distance_to(next) - distance
			stride_weight = smoothstep(0.0, PACE * 0.10, minf(distance, remaining))
		_walker.pose((_walked[index] + distance) / stride, direction, direction.x, false, stride_weight)


func _show_order(index: int, opacity: float) -> void:
	if _order.text != ORDERS[index]:
		_order.text = ORDERS[index]
		_order.reset_size()
		_order.position = Vector2(-_order.size.x * 0.5, -145.0 - _order.size.y)
	_order.modulate.a = opacity
	_order.visible = opacity > 0.0
