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


func _check_tether_length(world: Node, id: int, facing: float, sized_sled: bool) -> void:
	var view: Dictionary = world._views[id]
	var sled: Sprite2D = view.sled
	var tether: Line2D = view.tether
	view.facing = facing
	view.sled_factor = 2.0 if sized_sled else 1.0
	sled.scale = Presenter.SLED_BASE_SCALE * view.sled_factor
	view.quarry_haul = false
	view.tow_direction = Vector2(facing, 0)
	view.root.position = Vector2(facing * 430.0, 0)
	view.tow_route = PackedVector2Array([Vector2(0, -2), Vector2(facing * 4, 0), Vector2(facing * 8, 0)])
	view.tow_segment = 1
	view.walker.show()
	view.walker.pose(0.5, view.tow_direction, facing, true)
	var hand: Vector2 = view.walker.hand_position
	var offset := Vector2(facing * 50.0, -11.0) * float(view.sled_factor)
	var base := 68.0 if id == State.Owner.BUILDER else 94.0
	var distance: float = world._sled_distance(view, base)
	world._fit_sled_to_route(sled, view.tow_route, 1, view.root.position, facing, distance)
	var original_length := hand.distance_to(sled.position + offset.rotated(sled.rotation))
	world._update_sled(id, view, true, view.walker)
	_check(tether.visible and tether.get_point_position(0).is_equal_approx(hand)
		and tether.get_point_position(1).is_equal_approx(sled.position + offset.rotated(sled.rotation)),
		"The rope must connect the hand and hitch")
	_check(absf(tether.get_point_position(1).distance_to(hand) - original_length * 3.0) <= 0.1,
		"The rope must be three times its original length across a change of slope")


func _check_music_jump(world: Presenter, balance: Dictionary, resource_id: int) -> void:
	for source: int in [State.Owner.WORKSHOP_OUTPUT, State.Owner.QUARRY]:
		var finished := source == State.Owner.WORKSHOP_OUTPUT
		var id := State.Owner.BUILDER if finished else State.Owner.FIRST_PORTER
		var state := State.new(balance)
		state._move(resource_id, State.Owner.UNMINED, source)
		var loaded := state.reserve_transfer(id, [resource_id], source) and state.pick_up(id, resource_id)
		_check(loaded, "Cargo must be on the sled")
		if not loaded:
			continue
		world.sync_state(state, true)
		var view: Dictionary = world._views[id]
		view.quarry_haul = false
		view.tow_route = PackedVector2Array()
		view.tow_direction = Vector2(1.0, -0.4).normalized()
		var item: Sprite2D = view.items[0]
		world.render_frame(1.0, 0.0)
		_check(not is_zero_approx(view.sled.rotation), "Sled must be tilted during the jump test")
		var settled := item.global_position
		var slot := item.position
		world.render_frame(1.0, 0.0, 25.0)
		_check(item.global_position.is_equal_approx(settled + Vector2.UP * 25.0),
			"%s must jump vertically on the slope" % ("Finished brick" if finished else "Raw stone"))
		_check(item.position == slot, "Jump must preserve the transfer slot")
		world.render_frame(1.0, 0.0)
		_check(item.global_position.is_equal_approx(settled), "Cargo must land at its original position")
		state.worker(id).fsm_state = &"unload_at_lift" if finished else &"unload"
		world.sync_state(state)
		world.render_frame(1.0, 0.0, 25.0)
		var transfer_visible: bool = world._placing_brick.visible if finished else view.transfer_item.visible
		_check(view.sled_cargo.position == Vector2.ZERO and transfer_visible,
			"Manual unload must use its normal animation during a beat")


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
		var expected_scale: float = balance.world.brickWidth * 100.0 * size * Presenter.LIMESTONE_SCALE / item.texture.get_width()
		var expected_height_scale: float = balance.world.brickHeight * 100.0 * size * Presenter.LIMESTONE_SCALE / item.texture.get_height()
		_check((item.scale * view.sled.scale).is_equal_approx(Vector2(expected_scale, expected_height_scale)),
			"%dx%d cargo has incorrect world scale" % [size, size])
		var expected_sled_factor := maxf(1.0, float(size) * Presenter.LARGE_CARGO_SLED_FACTOR)
		_check(is_equal_approx(view.sled_factor, expected_sled_factor),
			"%dx%d single cargo has incorrect sled size" % [size, size])
		_check(absf(rect.get_center().x) < 0.1, "%dx%d cargo is off center" % [size, size])
		_check(absf(rect.end.y + 14.4 * expected_sled_factor) < 0.1,
			"%dx%d cargo is off the deck" % [size, size])
		print("CHECK: sled cargo %dx%d" % [size, size])
	sled_checks.check_mixed_layout(wallpaper)
	var mixed := State.new(balance)
	for resource_id in range(checked.blocks.size()):
		mixed._move(resource_id, State.Owner.UNMINED, porter_id)
	world._sync_sled_cargo(mixed, porter_id, view, false)
	var previous_right := -INF
	var deck_y: float = -14.4 * view.sled_factor
	_check(view.sled_factor >= 2.0, "Mixed batch has incorrect sled width")
	for index in range(checked.blocks.size()):
		var item: Sprite2D = view.items[index]
		var rect := _cargo_rect(item, view.sled)
		var size: int = int(checked.blocks[index].size)
		var expected_scale: Vector2 = Vector2(balance.world.brickWidth, balance.world.brickHeight) * (100.0 * size * Presenter.LIMESTONE_SCALE) / item.texture.get_size()
		_check((item.scale * view.sled.scale).is_equal_approx(expected_scale),
			"Mixed cargo %d has incorrect world scale" % index)
		_check(absf(rect.end.y - deck_y) < 0.1, "Mixed cargo %d is off the deck" % index)
		if index > 0:
			_check(absf(rect.position.x - previous_right - 4.0) < 0.1,
				"Mixed cargo %d has incorrect gap" % index)
		previous_right = rect.end.x
	_check(world._views[porter_id].items.size() >= checked.blocks.size(), "Mixed batch lost cargo sprites")
	_check(wallpaper.simulation.state.placed_count() == 0,
		"Layout test must not advance construction")
	_check_tether_length(world, porter_id, 1.0, false)
	_check_tether_length(world, State.Owner.BUILDER, -1.0, true)
	print("CHECK: threefold tether length with hand and hitch contact")
	_check_music_jump(world, balance, single_ids[4])
	print("CHECK: music jump and landing on a slope, raw stone and manual transfer")
	if _failures == 0:
		print("PASS: independent sled layout 1x1, 2x2, 4x4 and mixed; zero placements")
	else:
		print("FAIL: independent sled layout (%d assertions)" % _failures)
	quit(0 if _failures == 0 else 1)
