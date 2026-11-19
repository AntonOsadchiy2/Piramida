extends RefCounted

enum Role { MINER, DRESSER, LIFT, BUILDER, PORTER }

class Phase:
	var state: StringName
	var rate: float
	var route: PackedVector2Array
	var work: float

const Values = preload("res://scripts/domain/snapshot_values.gd")

const TIME_EPSILON := 1e-12

var id: int
var role: Role
var speed_multiplier: float = 1.0
var fsm_state: StringName = &"idle"
var position: Vector2
var path_segment: int = 0
var remaining_distance: float = 0.0
var remaining_work: float = 0.0
var route_waiting := false
var _phases: Array[Phase] = []


func _init(worker_id: int, worker_role: Role, initial_position: Vector2) -> void:
	id = worker_id
	role = worker_role
	position = initial_position


func queue_move(state: StringName, route: PackedVector2Array, speed: float) -> bool:
	if route.is_empty() or not is_finite(speed) or speed <= 0.0:
		return false
	var start := position
	for index in range(_phases.size() - 1, -1, -1):
		var previous_route := _phases[index].route
		if not previous_route.is_empty():
			start = previous_route[-1]
			break
	if route[0] != start:
		return false
	for point in route:
		if not point.is_finite():
			return false
	var phase := Phase.new()
	phase.state = state
	phase.route = route.duplicate()
	phase.rate = speed
	_queue_phase(phase)
	return true


func queue_work(state: StringName, amount: float, rate: float) -> bool:
	if not is_finite(amount) or amount < 0.0 or not is_finite(rate) or rate <= 0.0:
		return false
	var phase := Phase.new()
	phase.state = state
	phase.work = amount
	phase.rate = rate
	_queue_phase(phase)
	return true


func set_active_rate(rate: float) -> bool:
	if _phases.is_empty() or not is_finite(rate) or rate <= 0.0:
		return false
	_phases[0].rate = rate
	return true


func advance(seconds: float) -> Array[Dictionary]:
	var completed: Array[Dictionary] = []
	if route_waiting or not is_finite(seconds) or seconds <= 0.0:
		return completed
	var time_left := seconds
	# Each iteration either consumes a segment or phase, or ends the advance.
	while not _phases.is_empty():
		var phase := _phases[0]
		var rate := _effective_rate(phase)
		var moving := not phase.route.is_empty()
		var has_segment := moving and path_segment + 1 < phase.route.size()
		if has_segment:
			var arrival_time := remaining_distance / rate
			if arrival_time > time_left * (1.0 + TIME_EPSILON):
				remaining_distance -= rate * time_left
				var target := phase.route[path_segment + 1]
				var start := phase.route[path_segment]
				position = target.lerp(start, remaining_distance / start.distance_to(target))
				break
			time_left = maxf(0.0, time_left - arrival_time)
			path_segment += 1
			position = phase.route[path_segment]
			_load_segment()
			continue
		var work_time := remaining_work / rate
		if work_time > time_left * (1.0 + TIME_EPSILON):
			remaining_work -= rate * time_left
			break
		time_left = maxf(0.0, time_left - work_time)
		completed.append({"worker_id": id, "state": phase.state, "movement": moving})
		_phases.pop_front()
		_start_phase()
	return completed


func timing_snapshot() -> Dictionary:
	var phases: Array[Dictionary] = []
	for phase in _phases:
		var route: Array = []
		for point in phase.route:
			route.append([point.x, point.y])
		phases.append({
			"state": String(phase.state), "rate": phase.rate, "route": route, "work": phase.work,
		})
	return {
		"speed_multiplier": speed_multiplier, "id": id, "state": String(fsm_state), "position": [position.x, position.y],
		"path_segment": path_segment, "remaining_distance": remaining_distance,
		"remaining_work": remaining_work, "route_waiting": route_waiting, "phases": phases,
	}


func _effective_rate(phase: Phase) -> float:
	if phase.state in [&"rebuild_platform", &"operate_lift"]:
		return phase.rate
	return phase.rate * speed_multiplier


func _queue_phase(phase: Phase) -> void:
	_phases.append(phase)
	if _phases.size() == 1:
		_start_phase()


func _start_phase() -> void:
	path_segment = 0
	remaining_distance = 0.0
	remaining_work = 0.0
	if _phases.is_empty():
		fsm_state = &"idle"
		return
	var phase := _phases[0]
	fsm_state = phase.state
	remaining_work = phase.work
	_load_segment()


func _load_segment() -> void:
	var route := _phases[0].route
	remaining_distance = 0.0
	if path_segment + 1 < route.size():
		remaining_distance = route[path_segment].distance_to(route[path_segment + 1])


func movement_route() -> PackedVector2Array:
	return PackedVector2Array() if _phases.is_empty() else _phases[0].route


func replan_active_move(route: PackedVector2Array) -> bool:
	if _phases.is_empty() or _phases[0].route.is_empty() or route.is_empty() \
			or not route[0].is_equal_approx(position):
		return false
	_phases[0].route = route.duplicate()
	path_segment = 0
	remaining_distance = 0.0
	_load_segment()
	route_waiting = false
	return true


func segment_direction() -> Vector2:
	var route := movement_route()
	if path_segment + 1 >= route.size():
		return Vector2.ZERO
	return (route[path_segment + 1] - route[path_segment]).normalized()


func phase_work() -> float:
	return 0.0 if _phases.is_empty() else _phases[0].work


func phase_distance_traveled() -> float:
	if _phases.is_empty() or _phases[0].route.is_empty():
		return 0.0
	var route := _phases[0].route
	var distance := -remaining_distance
	for index in range(mini(path_segment + 1, route.size() - 1)):
		distance += route[index].distance_to(route[index + 1])
	return maxf(0.0, distance)


func relocate_waypoints(positions: Dictionary[Vector2, Vector2]) -> void:
	var routes: Array[PackedVector2Array] = []
	var new_position: Vector2 = positions.get(position, position)
	var changed := new_position != position
	for phase in _phases:
		if phase.route.is_empty():
			continue
		var route := phase.route.duplicate()
		for index in range(route.size()):
			var target: Vector2 = positions.get(route[index], route[index])
			changed = changed or route[index] != target
			route[index] = target
		routes.append(route)
	if changed:
		move_to_new_layout(routes, new_position)


func remap_saved_routes(map_route: Callable) -> bool:
	var routes: Array[PackedVector2Array] = []
	for phase in _phases:
		if not phase.route.is_empty():
			routes.append(map_route.call(phase.state, phase.route))
	return routes.is_empty() or move_to_new_layout(routes, position)


# Rebuild saved movement on a new layout, retaining the fraction of the active walk.
func move_to_new_layout(routes: Array[PackedVector2Array], work_position: Vector2) -> bool:
	var movement_count := 0
	for phase in _phases:
		movement_count += int(not phase.route.is_empty())
	if movement_count != routes.size():
		return false
	position = work_position
	var index := 0
	for phase in _phases:
		if phase.route.is_empty():
			continue
		var route := routes[index]
		index += 1
		if phase == _phases[0]:
			var old_length := _route_length(phase.route)
			var fraction := phase_distance_traveled() / old_length if old_length > 0.0 else 1.0
			_place_on_route(route, clampf(fraction, 0.0, 1.0))
		phase.route = route
	return true


# Quarry slope changes preserve world X, since the walls move under an active trip.
func follow_quarry_surface(make_route: Callable, work_position: Vector2) -> void:
	var previous_x := position.x
	position = work_position
	for phase in _phases:
		if phase.route.is_empty():
			continue
		phase.route = make_route.call(phase.route[0], phase.route[-1])
		if phase == _phases[0]:
			_place_on_route_at_x(phase.route, previous_x)


func _place_on_route_at_x(route: PackedVector2Array, x: float) -> void:
	path_segment = route.size() - 1
	position = route[-1]
	remaining_distance = 0.0
	for index in range(1, route.size()):
		var start := route[index - 1]
		var finish := route[index]
		if x >= minf(start.x, finish.x) and x <= maxf(start.x, finish.x):
			path_segment = index - 1
			position = start.lerp(finish, inverse_lerp(start.x, finish.x, x))
			remaining_distance = position.distance_to(finish)
			return


func _place_on_route(route: PackedVector2Array, fraction: float) -> void:
	var traveled := _route_length(route) * fraction
	path_segment = 0
	position = route[0]
	remaining_distance = 0.0
	for index in range(1, route.size()):
		var distance := route[index - 1].distance_to(route[index])
		if traveled < distance:
			remaining_distance = distance - traveled
			position = route[index - 1].lerp(route[index], traveled / distance)
			return
		traveled -= distance
		path_segment = index
		position = route[index]


func _route_length(route: PackedVector2Array) -> float:
	var distance := 0.0
	for index in range(1, route.size()):
		distance += route[index - 1].distance_to(route[index])
	return distance


func to_dict() -> Dictionary:
	var result := timing_snapshot()
	for key in ["remaining_work", "remaining_distance", "speed_multiplier"]:
		result[key] = Values.encode_real(result[key])
	for phase in result.phases:
		phase.rate = Values.encode_real(phase.rate)
		phase.work = Values.encode_real(phase.work)
	return result


# Restore the active phase exactly, including progress within a segment.
func restore_timing(data: Dictionary, allowed_states: Array) -> bool:
	var point: Variant = data.get("position")
	var phases: Variant = data.get("phases")
	var segment: Variant = data.get("path_segment")
	var distance: Variant = Values.decode_real(data.get("remaining_distance"))
	var work: Variant = Values.decode_real(data.get("remaining_work"))
	var multiplier: Variant = Values.decode_real(data.get("speed_multiplier"))
	var active: Variant = data.get("state")
	var saved_waiting: Variant = data.get("route_waiting", false)
	if not Values.point(point) or not phases is Array or not active is String \
			or not Values.integer(segment, 10000) or not Values.number(distance) \
			or not Values.number(work) or not Values.number(multiplier, 1.0) \
			or not saved_waiting is bool:
		return false
	for entry in phases:
		if not entry is Dictionary or entry.get("state") not in allowed_states \
				or not entry.get("route") is Array:
			return false
		var rate := Values.decode_real(entry.get("rate"))
		var amount := Values.decode_real(entry.get("work"))
		if not Values.number(rate, 1e-20) or not is_finite(rate * multiplier) or not Values.number(amount):
			return false
		var phase := Phase.new()
		phase.state = StringName(entry.state)
		phase.rate = rate
		phase.work = amount
		for vertex in entry.route:
			if not Values.point(vertex):
				return false
			phase.route.append(Vector2(vertex[0], vertex[1]))
		var moving := phase.state in [&"move_to_cell", &"lift_brick", &"walk_to_brick",
			&"return_to_platform", &"climb_to_platform", &"join_platform", &"walk_to_pickup", &"walk_to_storage",
			&"walk_to_workshop", &"walk_to_lift_base", &"walk_to_lift", &"return_from_lift",
			&"return_to_raw_storage", &"return_to_quarry"]
		if moving == phase.route.is_empty() or (moving and phase.work != 0.0):
			return false
		_phases.append(phase)
	if _phases.is_empty():
		if active != "idle" and (active != "exhausted" or role != Role.MINER):
			return false
		if segment != 0 or distance != 0 or work != 0:
			return false
	else:
		var phase := _phases[0]
		if active != String(phase.state) or work > phase.work or segment >= maxi(1, phase.route.size()):
			return false
		var length := 0.0
		if segment + 1 < phase.route.size():
			length = phase.route[segment].distance_to(phase.route[segment + 1])
		if distance > length:
			return false
	if saved_waiting and (_phases.is_empty() or _phases[0].route.is_empty()):
		return false
	fsm_state = StringName(active)
	position = Vector2(point[0], point[1])
	path_segment = int(segment)
	remaining_distance = distance
	remaining_work = work
	speed_multiplier = multiplier
	route_waiting = saved_waiting
	return true
