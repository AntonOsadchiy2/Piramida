extends Camera2D

var _bounds: Rect2


func _ready() -> void:
	get_viewport().size_changed.connect(_resize)
	set_process_input(false)


func setup(bounds: Rect2, _quarry: Rect2, _construction: Rect2) -> void:
	_bounds = bounds
	_resize()


func _resize() -> void:
	if not _bounds.has_area():
		return
	var size := get_viewport_rect().size
	zoom = Vector2.ONE * minf(size.x / _bounds.size.x, size.y / _bounds.size.y)
	position = _bounds.get_center()
	# Keep the surface at the original height in the wallpaper panorama.
	var half := size / (2.0 * zoom.x)
	position.y = -half.y * 0.58
	force_update_scroll()
