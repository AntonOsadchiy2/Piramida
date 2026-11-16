extends Node2D
## Site lighting follows the displayed sky and survives construction resets.

const TorchScene := preload("res://assets/wallpaper/torches/torch.tscn")
const Overseer := preload("res://scripts/presentation/site_overseer.gd")
const Presenter := preload("res://scripts/presentation/world_presenter.gd")
const TORCH_OFFSET := Vector2(34, 0)
const WICK_OFFSET := Vector2(0, -91)
const TEND_SECONDS := 0.58
const LIGHT_AT := 0.26
const EXTINGUISH_AT := 0.17
const FADE_SECONDS := 0.38

class Torch:
	var stand: Node2D
	var flame: ColorRect
	var light: PointLight2D
	var burning := false
	var tending := false
	var strength := 0.0
	var phase: float

var _torches: Array[Torch] = []
var _want_fire := false
var _initialized := false


func attach_to_patrol(overseer: Overseer, geometry: Presenter.Geometry,
		workers: Array[Node2D]) -> void:
	var quarry_x := Presenter.screen_point(geometry.quarry_mouth()).x
	var workshop_x := Presenter.screen_point(geometry.workshop()).x
	var pyramid_left := Presenter.screen_point(geometry.brick_origin(0, 0)).x
	var positions := PackedVector2Array([
		Vector2(quarry_x - 375, 0),
		Vector2(quarry_x + 10, 0),
		Vector2(quarry_x + 420, 0),
		Vector2(workshop_x + 309, 0),
		Vector2(pyramid_left - 17, 0),
	])
	var stops := PackedVector2Array()
	for point in positions:
		stops.append(point - TORCH_OFFSET)
	overseer.setup(stops, [workers[0], workers[0], workers[0], workers[1], workers[2]], false, true)

	if _torches.is_empty():
		for point in positions:
			var torch := Torch.new()
			torch.stand = TorchScene.instantiate()
			torch.stand.position = point
			torch.flame = torch.stand.get_node("Flame")
			torch.light = torch.stand.get_node("Light")
			torch.phase = float(_torches.size()) * 2.7
			(torch.flame.material as ShaderMaterial).set_shader_parameter("phase", torch.phase)
			add_child(torch.stand)
			_torches.append(torch)
	for torch in _torches:
		torch.tending = false
	overseer.stop_action = _tend


func update_darkness(night_weight: float) -> void:
	if not _initialized:
		# When opened after dusk, the site is already lit.
		_want_fire = night_weight >= LIGHT_AT
		for torch in _torches:
			torch.burning = _want_fire
			torch.strength = 1.0 if _want_fire else 0.0
			_render_torch(torch, 0.0)
		_initialized = true
	elif night_weight >= LIGHT_AT:
		_want_fire = true
	elif night_weight <= EXTINGUISH_AT:
		_want_fire = false


func _tend(index: int, order_time: float) -> Vector2:
	var torch := _torches[index]
	if order_time < 0.0:
		torch.tending = false
		return Vector2.INF
	if torch.burning != _want_fire:
		torch.tending = true
		if order_time >= TEND_SECONDS:
			torch.burning = _want_fire
	return torch.stand.to_global(WICK_OFFSET) if torch.tending else Vector2.INF


func _process(delta: float) -> void:
	var seconds := Time.get_ticks_msec() * 0.001
	for torch in _torches:
		if torch.burning or torch.strength > 0.0:
			torch.strength = move_toward(torch.strength, 1.0 if torch.burning else 0.0,
				delta / FADE_SECONDS)
			_render_torch(torch, seconds)


func _render_torch(torch: Torch, seconds: float) -> void:
	var time := seconds + torch.phase
	var flicker := 0.72 + 0.06 * sin(11.0 * time) + 0.04 * sin(19.0 * time)
	var visible := torch.strength > 0.0
	torch.flame.visible = visible
	torch.flame.self_modulate.a = torch.strength
	torch.light.enabled = visible
	torch.light.energy = flicker * torch.strength
