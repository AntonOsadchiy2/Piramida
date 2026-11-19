extends "res://tests/wallpaper_cycles.gd"

# Exercise the production completion path on a small, known-buildable blueprint.
const Blueprint = preload("res://scripts/domain/blueprint.gd")
const BLOCKS := [
	{"x": 0, "y": 0, "type": "stone", "size": 4},
	{"x": 4, "y": 0, "type": "stone", "size": 2},
	{"x": 6, "y": 0, "type": "stone", "size": 1},
	{"x": 6, "y": 1, "type": "stone", "size": 1},
	{"x": 4, "y": 2, "type": "stone", "size": 2},
	{"x": 0, "y": 4, "type": "stone", "size": 4},
]
const MAX_TICKS := 4000


func _run() -> void:
	var wallpaper := WALLPAPER.instantiate()
	wallpaper.use_temporary_save = true
	root.add_child(wallpaper)
	wallpaper.set_process(false)
	if wallpaper._temporary_save_dir == null:
		quit(1)
		return
	var balance: Dictionary = wallpaper._balance.duplicate(true)
	var checked: Dictionary = Blueprint.validate({"version": 2, "blocks": BLOCKS})
	_check(not checked.has("error"), "Small blueprint is valid")
	balance.world["blueprintBlocks"] = checked.blocks
	balance.world.pyramidRows = 4
	var save_path: String = wallpaper._temporary_save_dir.get_current_dir().path_join("small-save.json")
	wallpaper._apply_panel_config({"balance": balance, "settings": {}, "save_path": save_path, "key": "small-completion"})
	_check(wallpaper._start_cycle(), "Small blueprint starts with isolated save")
	var fresh: Dictionary = wallpaper.simulation.to_dict()
	var overview: Array = _camera_view(wallpaper)
	var counts: Array = _scene_counts(wallpaper)
	_check(wallpaper.simulation.state.target_count() == BLOCKS.size(), "Six-block target is active")
	var before_final_tick := 0
	var ticks := 0
	for tick in range(MAX_TICKS):
		before_final_tick = Time.get_ticks_msec()
		wallpaper._process(wallpaper._step)
		ticks += 1
		if wallpaper.simulation.state.finished or failures > 0:
			break
		if tick % 32 == 0:
			await process_frame
	var state: State = wallpaper.simulation.state
	_check(state.finished and state.placed_count() == BLOCKS.size(), "Normal production completes all six blocks")
	_check(state.validate().is_empty(), "Finished ownership and reservations are valid")
	if not state.finished:
		var builder := state.worker(state.active_builder_id)
		print("[SCENARIO] FAIL small-completion tick=%d placed=%d row=%d phase=%s pos=%s waiting=%s delivery=%s work=%s" % [
			ticks, state.placed_count(), state.current_row, builder.fsm_state,
			str(builder.position), str(wallpaper.simulation._construction.waiting_snapshot()),
			str(state.delivery_point), str(wallpaper.simulation._construction._placement_point())])
		wallpaper.free()
		quit(1)
		return
	_check(_placed_tiles(wallpaper.world.pyramid) == 2
		and wallpaper.world._large_brick_sprites.values().all(func(sprite): return is_equal_approx(sprite.modulate.a, 1.0)),
		"Two small tiles and four large blocks remain visible")
	var old_world: Node = wallpaper.world
	var lighting: Node = wallpaper._light
	var sky = wallpaper._sky
	var completed: Dictionary = wallpaper.simulation.to_dict()
	var deadline: int = wallpaper._restart_at_msec
	_check(deadline >= before_final_tick + 5000 and deadline <= Time.get_ticks_msec() + 5000,
		"Production sets a real 5000 ms deadline")
	var samples := 0
	while Time.get_ticks_msec() < deadline - 50:
		wallpaper._process(0.01)
		_check(wallpaper.world == old_world and wallpaper.simulation.to_dict() == completed,
			"Completed world and simulation stay frozen during hold")
		samples += 1
		if failures > 0:
			break
		await create_timer(0.05).timeout
	_check(samples > 0, "Real hold was sampled")
	while Time.get_ticks_msec() < deadline and failures == 0:
		await process_frame
	if failures == 0:
		wallpaper._process(0.01)
		_check(not is_instance_valid(old_world), "Old world is freed after hold")
		_check(wallpaper.simulation.to_dict() == fresh, "Workers, inventory, tasks and counters reset cleanly")
		_check(wallpaper._light == lighting and wallpaper._sky == sky, "Lighting and sky survive reset")
		_check(_scene_counts(wallpaper) == counts and _placed_tiles(wallpaper.world.pyramid) == 0
			and wallpaper.world._large_brick_sprites.values().all(func(sprite): return is_equal_approx(sprite.modulate.a, 0.18)),
			"Tiles, quarry and scene nodes reset cleanly")
		_check(_camera_view(wallpaper) == overview and root.get_camera_2d() == wallpaper.world.get_node("Camera2D"),
			"First reset frame retains the active overview")
		_check(wallpaper.world._effects.values().all(func(sprite): return not sprite.visible)
			and wallpaper.world._effect_tweens.is_empty(), "No transient effects survive reset")
		for frame in range(3):
			await process_frame
			_check(_camera_view(wallpaper) == overview, "Overview stays stable after reset frame %d" % frame)
	print("[SCENARIO] %s small-completion ticks=%d placed=%d hold=5000ms" % [
		"PASS" if failures == 0 else "FAIL", ticks, BLOCKS.size()])
	wallpaper.free()
	quit(int(failures > 0))
