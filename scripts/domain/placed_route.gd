extends RefCounted

## Routes over exposed masonry, ground and already validated scaffold sections.
## A transition is the only way to change height or cross an unsupported span.
## The result is independent of worker state and can be queried again after placement.
static func find_path(geometry, placed: Dictionary, scaffolds: Array,
		start: Vector2, finish: Vector2, settings: Dictionary = {}) -> Dictionary:
	var unit: Vector2 = geometry.brick_size()
	var width: float = float(settings.get("worker_width", 0.18 * unit.x))
	var height: float = float(settings.get("worker_height", 0.9 * unit.y))
	var clearance: float = float(settings.get("clearance", 0.02 * unit.y))
	var failure := {"ok": false, "reason": "invalid_settings", "points": PackedVector2Array(), "edges": []}
	if width <= 0.0 or height <= 0.0 or clearance < 0.0:
		return failure
	var walks: Array[Dictionary] = []
	var include_surfaces: bool = bool(settings.get("include_surfaces", true))
	for surface: Dictionary in placed.get("surfaces", []):
		if include_surfaces or str(surface.get("source", "")) == "ground":
			walks.append({"id": str(surface.id), "x0": float(surface.x0),
				"x1": float(surface.x1), "y": float(surface.y)})
	var transitions: Array[Dictionary] = []
	for scaffold: Dictionary in scaffolds:
		if not _valid_scaffold(geometry, placed, scaffold, width, height, clearance, scaffolds):
			continue
		for section: Dictionary in scaffold.get("sections", []):
			walks.append({"id": str(section.id), "x0": float(section.x0),
				"x1": float(section.x1), "y": float(section.y)})
		for transition: Dictionary in scaffold.get("transitions", []):
			transitions.append(transition)
	walks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.id) < str(b.id))
	transitions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.id) < str(b.id))
	var points: Array[Vector2] = []
	var start_id := _add_point(points, start)
	var finish_id := _add_point(points, finish)
	for walk in walks:
		if not is_inf(walk.x0):
			_add_point(points, Vector2(walk.x0, walk.y))
		if not is_inf(walk.x1):
			_add_point(points, Vector2(walk.x1, walk.y))
		for point in [start, finish]:
			if _on_walk(walk, point):
				_add_point(points, point)
	for transition in transitions:
		_add_point(points, transition["from"])
		_add_point(points, transition["to"])
	var adjacency: Array[Array] = []
	for _point in points:
		adjacency.append([])
	for walk in walks:
		var members: Array[int] = []
		for i in range(points.size()):
			if _on_walk(walk, points[i]):
				members.append(i)
		members.sort_custom(func(a: int, b: int) -> bool:
			return points[a].x < points[b].x)
		for i in range(1, members.size()):
			_link(geometry, placed, points, adjacency, members[i - 1], members[i],
				str(walk.id), width, height, clearance)
	for transition in transitions:
		var members: Array[int] = []
		for point in [transition["from"], start, finish, transition["to"]]:
			if _on_transition(transition, point):
				var id := _add_point(points, point)
				if not members.has(id):
					members.append(id)
		members.sort_custom(func(a: int, b: int) -> bool:
			return points[a].distance_to(transition["from"]) \
				< points[b].distance_to(transition["from"]))
		for i in range(1, members.size()):
			_link(geometry, placed, points, adjacency, members[i - 1], members[i],
				str(transition.id), width, height, clearance)
	if not _has_access(geometry, placed, walks, transitions, start, width, height, clearance):
		failure.reason = "start_unreachable"
		return failure
	if not _has_access(geometry, placed, walks, transitions, finish, width, height, clearance):
		failure.reason = "finish_unreachable"
		return failure
	var distance: Array[float] = []
	var previous: Array[int] = []
	var previous_edge: Array[String] = []
	var visited: Array[bool] = []
	for _point in points:
		distance.append(INF)
		previous.append(-1)
		previous_edge.append("")
		visited.append(false)
	distance[start_id] = 0.0
	for _step in range(points.size()):
		var current := -1
		for i in range(points.size()):
			if not visited[i] and (current < 0 or distance[i] < distance[current]):
				current = i
		if current < 0 or is_inf(distance[current]) or current == finish_id:
			break
		visited[current] = true
		for edge: Dictionary in adjacency[current]:
			var next: int = edge.to
			var cost: float = distance[current] + points[current].distance_to(points[next])
			if cost + 0.00001 < distance[next]:
				distance[next] = cost
				previous[next] = current
				previous_edge[next] = edge.id
	if is_inf(distance[finish_id]):
		failure.reason = "disconnected"
		return failure
	var reverse_points: Array[Vector2] = []
	var reverse_edges: Array[String] = []
	var cursor := finish_id
	while cursor >= 0:
		reverse_points.append(points[cursor])
		if previous[cursor] >= 0:
			reverse_edges.append(previous_edge[cursor])
		cursor = previous[cursor]
	reverse_points.reverse()
	reverse_edges.reverse()
	var route := PackedVector2Array(reverse_points)
	return {"ok": true, "reason": "", "points": route, "edges": reverse_edges,
		"length": distance[finish_id]}


static func _add_point(points: Array[Vector2], point: Vector2) -> int:
	for i in range(points.size()):
		if points[i].distance_to(point) < 0.00001:
			return i
	points.append(point)
	return points.size() - 1


static func _on_walk(walk: Dictionary, point: Vector2) -> bool:
	return is_equal_approx(point.y, walk.y) and point.x >= walk.x0 - 0.00001 \
		and point.x <= walk.x1 + 0.00001


static func _on_transition(transition: Dictionary, point: Vector2) -> bool:
	var start: Vector2 = transition["from"]
	var finish: Vector2 = transition["to"]
	var length := start.distance_to(finish)
	return length > 0.00001 and absf(start.distance_to(point)
		+ point.distance_to(finish) - length) < 0.0001


## Checks the saved edge itself; another, shorter path must not move a restored worker.
static func has_segment(geometry, placed: Dictionary, scaffolds: Array,
		start: Vector2, finish: Vector2, settings: Dictionary = {}) -> bool:
	var unit: Vector2 = geometry.brick_size()
	var width: float = float(settings.get("worker_width", 0.18 * unit.x))
	var height: float = float(settings.get("worker_height", 0.9 * unit.y))
	var clearance: float = float(settings.get("clearance", 0.02 * unit.y))
	if not geometry._scaffold_clear_segment(placed, start, finish, width, height, clearance):
		return false
	for surface: Dictionary in placed.surfaces:
		if bool(settings.get("include_surfaces", true)) or str(surface.source) == "ground":
			if _on_walk(surface, start) and _on_walk(surface, finish):
				return true
	for scaffold: Dictionary in scaffolds:
		if not _valid_scaffold(geometry, placed, scaffold, width, height, clearance, scaffolds):
			continue
		for section: Dictionary in scaffold.sections:
			if _on_walk(section, start) and _on_walk(section, finish):
				return true
		for transition: Dictionary in scaffold.transitions:
			if (start.is_equal_approx(transition["from"])
					and finish.is_equal_approx(transition["to"])) \
					or (finish.is_equal_approx(transition["from"])
					and start.is_equal_approx(transition["to"])):
				return true
	return false


static func _link(geometry, placed: Dictionary, points: Array[Vector2],
		adjacency: Array[Array], a: int, b: int, edge_id: String,
		width: float, height: float, clearance: float) -> void:
	if a == b or not geometry._scaffold_clear_segment(placed, points[a], points[b],
			width, height, clearance):
		return
	adjacency[a].append({"to": b, "id": edge_id})
	adjacency[b].append({"to": a, "id": edge_id})


static func _has_access(geometry, placed: Dictionary, walks: Array[Dictionary],
		transitions: Array[Dictionary], point: Vector2,
		width: float, height: float, clearance: float) -> bool:
	if not geometry._scaffold_clear_segment(placed, point, point, width, height, clearance):
		return false
	for walk in walks:
		if _on_walk(walk, point):
			return true
	for transition in transitions:
		if _on_transition(transition, point):
			return true
	return false


static func _valid_scaffold(geometry, placed: Dictionary, scaffold: Dictionary,
		width: float, height: float, clearance: float,
		all_scaffolds: Array = []) -> bool:
	if not bool(scaffold.get("ok", false)):
		return false
	for post: Dictionary in scaffold.get("posts", []):
		var support: Dictionary = geometry.support_below(placed,
			Vector2((float(post.x0) + float(post.x1)) * 0.5, float(post.y1)))
		if support.is_empty() or str(support.id) != str(post.support_id) \
				or not is_equal_approx(float(support.y), float(post.y0)) \
				or float(support.x0) > float(post.x0) \
				or float(support.x1) < float(post.x1):
			return false
		for block: Dictionary in placed.blocks:
			if block.x0 < post.x1 and block.x1 > post.x0 \
					and block.y0 < post.y1 and block.y1 > post.y0:
				return false
	for section: Dictionary in scaffold.get("sections", []):
		if not geometry._scaffold_clear_segment(placed,
				Vector2(section.x0, section.y), Vector2(section.x1, section.y),
				width, height, clearance):
			return false
	for transition: Dictionary in scaffold.get("transitions", []):
		for point: Vector2 in [transition["from"], transition["to"]]:
			var supported := false
			for surface: Dictionary in placed.surfaces:
				if _on_walk(surface, point):
					supported = true
					break
			for section: Dictionary in scaffold.get("sections", []):
				if _on_walk(section, point):
					supported = true
					break
			if not supported:
				for other: Dictionary in all_scaffolds:
					for section: Dictionary in other.get("sections", []):
						if _on_walk(section, point):
							supported = true
							break
					if supported:
						break
			if not supported:
				return false
		if not geometry._scaffold_clear_segment(placed, transition["from"],
				transition["to"], width, height, clearance):
			return false
	return true
