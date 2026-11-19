extends SceneTree

const WallpaperScene = preload("res://scenes/wallpaper.tscn")
const Blueprint = preload("res://scripts/domain/blueprint.gd")
const State = preload("res://scripts/domain/game_state.gd")
const Simulation = preload("res://scripts/simulation/simulation_runner.gd")
const SaveService = preload("res://scripts/application/save_service.gd")
const Presenter = preload("res://scripts/presentation/world_presenter.gd")
const LargeBlockChecks = preload("res://tests/blueprint_large_blocks.gd")
const SledChecks = preload("res://tests/sled_cargo.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		push_error(message)


func _cargo_rect(item: Sprite2D, sled: Sprite2D) -> Rect2:
	var visible: Rect2 = item.texture.get_meta("cargo_bounds")
	visible.position -= item.texture.get_size() * 0.5
	return Rect2((item.position + visible.position * item.scale) * sled.scale,
		visible.size * item.scale * sled.scale)


func _run() -> void:
	var wallpaper = WallpaperScene.instantiate()
	wallpaper.use_temporary_save = true
	root.add_child(wallpaper)
	wallpaper.set_process(false)
	_check(wallpaper._temporary_save_dir != null, "Wallpaper saves must use a temporary directory")
	var checked := Blueprint.validate({"version": 2, "blocks": LargeBlockChecks.MIXED})
	_check(not checked.has("error"), "Mixed fixture must be valid")
	if _failures > 0:
		quit(1)
		return
	var balance: Dictionary = wallpaper._balance.duplicate(true)
	balance.world["blueprintBlocks"] = checked.blocks
	balance.world.pyramidRows = 4
	wallpaper._balance = balance
	wallpaper._save_service = SaveService.new(balance,
		wallpaper._temporary_save_dir.get_current_dir().path_join("layout-save.json"))
	_check(wallpaper._start_cycle(Simulation.for_wallpaper(balance)), "Mixed wallpaper must start")
	var sled_checks := SledChecks.new()
	sled_checks.check_scaffold_clearance(wallpaper)
	var world = wallpaper.world
	var porter_id := State.Owner.FIRST_PORTER
	var view: Dictionary = world._views[porter_id]
	var single_ids := {}
	for resource_id in range(checked.blocks.size()):
		single_ids[int(checked.blocks[resource_id].size)] = resource_id
	for size in [1, 2, 4]:
		var state := State.new(balance)
		state._move(single_ids[size], State.Owner.UNMINED, porter_id)
		world._sync_sled_cargo(state, porter_id, view, false)
		var item: Sprite2D = view.items[0]
		var rect := _cargo_rect(item, view.sled)
		_check((item.scale * view.sled.scale).is_equal_approx(Presenter.RAW_STONE_SCALE * size),
			"%dx%d cargo has incorrect world scale" % [size, size])
		_check(is_equal_approx(view.sled_factor, float(size)),
			"%dx%d single cargo has incorrect sled size" % [size, size])
		if size == 1:
			# The original single-stone slot is offset left and slightly above the deck.
			_check(absf(rect.position.x + 57.32) < 0.1, "1x1 cargo moved from its original slot")
			_check(absf(rect.end.y + 16.05) < 0.1, "1x1 cargo lost deck contact")
		else:
			# The visible rectangle must be centered and rest on the wooden deck.
			_check(absf(rect.get_center().x) < 0.1, "%dx%d cargo is off center" % [size, size])
			_check(absf(rect.end.y + 14.4 * size) < 0.1, "%dx%d cargo is off the deck" % [size, size])
			_check(rect.position.x >= -45.0 * size - 0.1 and rect.end.x <= 45.0 * size + 0.1,
				"%dx%d cargo exceeds deck width" % [size, size])
		print("CHECK: sled cargo %dx%d" % [size, size])
	sled_checks.check_mixed_layout(wallpaper)
	var mixed := State.new(balance)
	for resource_id in range(checked.blocks.size()):
		mixed._move(resource_id, State.Owner.UNMINED, porter_id)
	world._sync_sled_cargo(mixed, porter_id, view, false)
	var previous_right := -INF
	var deck_y: float = -14.4 * view.sled_factor
	var deck_half_width: float = 45.0 * view.sled_factor
	_check(absf(view.sled_factor - 6.9484444) < 0.001,
		"Mixed batch has incorrect sled width")
	for index in range(checked.blocks.size()):
		var item: Sprite2D = view.items[index]
		var rect := _cargo_rect(item, view.sled)
		var size: int = int(checked.blocks[index].size)
		_check((item.scale * view.sled.scale).is_equal_approx(Presenter.RAW_STONE_SCALE * size),
			"Mixed cargo %d has incorrect world scale" % index)
		_check(rect.position.x >= -deck_half_width - 0.1 and rect.end.x <= deck_half_width + 0.1,
			"Mixed cargo %d exceeds deck width" % index)
		_check(absf(rect.end.y - deck_y) < 0.1, "Mixed cargo %d is off the deck" % index)
		if index > 0:
			_check(absf(rect.position.x - previous_right - 4.0) < 0.1,
				"Mixed cargo %d has incorrect gap" % index)
		previous_right = rect.end.x
	_check(world._views[porter_id].items.size() >= checked.blocks.size(), "Mixed batch lost cargo sprites")
	_check(wallpaper.simulation.state.placed_count() == 0,
		"Layout test must not advance construction")
	if _failures == 0:
		print("PASS: independent sled layout 1x1, 2x2, 4x4 and mixed; zero placements")
	else:
		print("FAIL: independent sled layout (%d assertions)" % _failures)
	quit(0 if _failures == 0 else 1)
