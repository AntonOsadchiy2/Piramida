extends "res://tests/wallpaper_cycles.gd"

# Reuse the Windows scene harness and its camera, tile and transfer probes.
# Preparation advances only the normal model; playback uses wallpaper._process.
const SCENARIOS := ["first-lift", "row-end", "completion", "transfer-resume"]
const PREPARE_MAX_TICKS := 400000
const PLAY_MAX_TICKS := 5000

var _scenario := ""
var _visual := false
var _played_ticks := 0
var _last_frame_usec := 0
var _capture_dir := ""


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	for index in range(args.size()):
		if args[index] == "--scenario" and index + 1 < args.size():
			_scenario = args[index + 1]
		if args[index] == "--capture-dir" and index + 1 < args.size():
			_capture_dir = args[index + 1]
	_visual = args.has("--visual")
	if not _scenario in SCENARIOS:
		printerr("Use -- --scenario <%s> [--visual]" % ", ".join(SCENARIOS))
		quit(2)
		return
	if _visual and DisplayServer.get_name() == "headless":
		printerr("--visual requires a window")
		quit(2)
		return
	Engine.max_fps = 60 if _visual else 0
	var wallpaper := WALLPAPER.instantiate()
	# Must precede _ready: neither the normal save nor its backup is accessed.
	wallpaper.use_temporary_save = true
	root.add_child(wallpaper)
	wallpaper.set_process(false)
	if wallpaper._temporary_save_dir == null:
		wallpaper.free()
		quit(1)
		return
	await process_frame
	var fresh: Dictionary = wallpaper.simulation.to_dict()
	var overview := _camera_view(wallpaper)
	var scene_counts := _scene_counts(wallpaper)
	var prepared := _prepare(wallpaper._balance)
	if prepared == null:
		wallpaper.free()
		quit(1)
		return
	# Exercise the existing snapshot contract, without editing inventory or tasks.
	var restored := Simulation.from_dict(wallpaper._balance, prepared.to_dict())
	_check(restored != null, "Prepared simulation restores through the snapshot contract")
	if restored == null:
		wallpaper.free()
		quit(1)
		return
	wallpaper._start_cycle(restored)
	_check(wallpaper.simulation.to_dict() == prepared.to_dict(), "Exact prepared state")
	_check(wallpaper.simulation.state.validate().is_empty(), "Valid initial ownership and reservations")
	print("[SCENARIO] START %s tick=%d placed=%d row=%d phase=%s" % [
		_scenario, restored.to_dict().tick, restored.state.placed_count(), restored.state.current_row,
		restored.state.worker(BUILDER).fsm_state])
	await _capture(wallpaper, "start")
	_last_frame_usec = Time.get_ticks_usec()
	match _scenario:
		"first-lift":
			await _first_lift(wallpaper)
		"row-end":
			await _row_end(wallpaper)
		"completion":
			await _completion(wallpaper, fresh, overview, scene_counts)
		"transfer-resume":
			await _transfer_resume(wallpaper)
	_check(wallpaper.simulation.state.validate().is_empty(), "Valid final ownership and reservations")
	await _capture(wallpaper, "result")
	print("[SCENARIO] %s %s ticks=%d placed=%d row=%d" % [
		"PASS" if failures == 0 else "FAIL", _scenario, _played_ticks,
		wallpaper.simulation.state.placed_count(), wallpaper.simulation.state.current_row])
	wallpaper.free()
	quit(int(failures > 0))


func _prepare(balance: Dictionary) -> Simulation:
	var candidate: Simulation = Simulation.for_wallpaper(balance)
	for tick in range(PREPARE_MAX_TICKS):
		var state: State = candidate.state
		if _scenario == "completion" and tick > 0 and tick % 5000 == 0:
			print("[SCENARIO] PREPARE completion tick=%d placed=%d row=%d" % [
				tick, state.placed_count(), state.current_row])
		var builder := state.worker(BUILDER)
		var reached := false
		match _scenario:
			"first-lift":
				reached = state.current_row == 1 and state.placed_count() == 59 \
					and builder.fsm_state == &"walk_to_lift"
			"row-end":
				reached = state.current_row == 1 and state.placed_count() == 115 \
					and builder.fsm_state == &"place_brick"
			"completion":
				reached = state.placed_count() == 899 and builder.fsm_state == &"place_brick"
			"transfer-resume":
				# First mid-load on the leftward approach (tick 57 with the current balance).
				var porter := state.worker(PORTER)
				reached = porter.fsm_state == &"load" and state.transfer_source(PORTER) == State.Owner.QUARRY \
					and porter.remaining_work > 0.0 and porter.remaining_work < porter.phase_work() \
					and state.stock_count(PORTER) == 0
		if reached:
			return candidate
		if state.finished:
			break
		candidate.step_simulation()
	_check(false, "Preparation did not reach %s within %d ticks" % [_scenario, PREPARE_MAX_TICKS])
	return null


func _advance(wallpaper) -> void:
	var before: int = wallpaper.simulation._tick
	if _visual:
		while wallpaper.simulation._tick == before:
			await process_frame
			var now := Time.get_ticks_usec()
			# At most one fixed step per call, while retaining frame interpolation.
			var delta := minf((now - _last_frame_usec) * 0.000001, wallpaper._step * 0.5)
			_last_frame_usec = now
			wallpaper._process(delta)
	else:
		wallpaper._process(wallpaper._step)
		if _played_ticks % 32 == 0:
			await process_frame
	_played_ticks += 1
	_check(wallpaper.simulation.state.validate().is_empty(), "Ownership/reservations after tick %d" % _played_ticks)
	_check(wallpaper.simulation.state.placed_count() <= State.RESOURCE_COUNT, "At most 900 bricks")


func _first_lift(wallpaper) -> void:
	var seen := {}
	var checked_crank := false
	var overseer: Walk = wallpaper.world.overseer._walker
	_check(is_equal_approx(overseer.scale.y, 0.9375), "Overseer uses 75% of the original worker scale")
	for view: Dictionary in wallpaper.world._views.values():
		if view.has("walker"):
			_check(is_equal_approx(view.walker.scale.y, overseer.scale.y), "Workers and overseer share one scale")
	for tick in range(PLAY_MAX_TICKS):
		var state: State = wallpaper.simulation.state
		var builder := state.worker(BUILDER)
		var lift := state.worker(State.Owner.LIFT)
		seen[builder.fsm_state] = true
		if lift.fsm_state == &"lift_brick":
			seen[&"lift_brick"] = true
			_check(state.stock_count(State.Owner.LIFT) == 1, "Lift carries exactly one brick")
		if state.stock_count(State.Owner.PLATFORM) > 0:
			seen[&"platform_stock"] = true
		if builder.fsm_state == &"operate_lift":
			var view: Dictionary = wallpaper.world._views[BUILDER]
			_check(view.cranking, "Builder operates the crank during lift travel")
			var walker: Walk = view.walker
			if not checked_crank and walker._near_arm.z_index == 1:
				_check_crank_orbit(wallpaper.world, walker)
				checked_crank = true
		if builder.fsm_state == &"walk_to_brick":
			_check(state.stock_count(BUILDER) == 1, "Builder hauls one brick from the landing")
		if state.placed_count() == 60:
			_check(checked_crank, "Builder reached the scaled crank")
			_check(state.current_row == 1 and state.completed_rows == 1, "First upper brick stays on row 1")
			_check(builder.fsm_state == &"return_to_platform" and state.stock_count(BUILDER) == 0,
				"Builder returns empty after brick 60")
			_check(_placed_tiles(wallpaper.world.pyramid) == 60, "Scene contains exactly 60 laid tiles")
			for phase in [&"walk_to_lift", &"operate_lift", &"lift_brick", &"platform_stock",
					&"walk_to_brick", &"place_brick"]:
				_check(seen.has(phase), "First lift passed through " + str(phase))
			print("First lift: approach -> crank -> landing -> haul -> placement 60 -> empty return")
			return
		if failures > 0:
			return
		await _advance(wallpaper)
	_check(false, "First lift timed out: " + _describe(wallpaper))


func _row_end(wallpaper) -> void:
	var seen_return := false
	var seen_rebuild := false
	var seen_climb := false
	var checked_edge := false
	var old_road := PackedVector2Array()
	for tick in range(PLAY_MAX_TICKS):
		var state: State = wallpaper.simulation.state
		var builder := state.worker(BUILDER)
		var deck: Sprite2D = wallpaper.world._deck
		if builder.fsm_state == &"rebuild_platform":
			seen_rebuild = true
			_check(wallpaper.world._scaffold_root.visible, "Scaffolds stay visible during rebuilding")
		if builder.fsm_state == &"climb_to_platform":
			seen_climb = true
			_check(state.current_row == 2 and state.row_start == 116, "New row starts after brick 116")
			_check(state.scaffold_paths.size() == 2 and state.scaffold_paths[0] == old_road
				and state.scaffold_paths[1][-1] == state.delivery_point,
				"Two rows share the old floor and the new floor ends at delivery")
		if state.placed_count() == 116 and builder.fsm_state == &"return_to_platform":
			seen_return = true
			_check(state.completed_rows == 2 and state.current_row == 1, "Row completes once before rebuilding")
			_check(state.stock_count(BUILDER) == 0, "Builder returns empty from the row end")
		if state.placed_count() == 117:
			_check(seen_return and seen_rebuild and seen_climb and checked_edge, "Full row transition observed")
			_check(state.completed_rows == 2 and state.current_row == 2, "Next brick belongs to row 2")
			_check(_placed_tiles(wallpaper.world.pyramid) == 117, "Scene contains 117 laid tiles")
			print("Row end: 115 -> 116 -> empty return -> rebuild -> climb -> 117")
			return
		var before := state.placed_count()
		await _advance(wallpaper)
		if before == 115 and state.placed_count() == 116:
			var route := builder.movement_route()
			old_road = state.scaffold_paths[0]
			_check(not route.is_empty() and old_road.has(route[-1]),
				"Return uses the existing row before the next road is built")
			if not route.is_empty():
				_check(wallpaper.world._scaffold_root.visible and not deck.visible
					and route[0].is_equal_approx(builder.position),
					"Return starts at the builder's safe position on the shared scaffold model")
				checked_edge = true
				await _capture(wallpaper, "return")
		if failures > 0:
			return
	_check(false, "Row end timed out: " + _describe(wallpaper))


func _completion(wallpaper, fresh: Dictionary, overview: Array, scene_counts: Array) -> void:
	var before_final_tick := 0
	for tick in range(PLAY_MAX_TICKS):
		before_final_tick = Time.get_ticks_msec()
		await _advance(wallpaper)
		if wallpaper.simulation.state.finished or failures > 0:
			break
	var state: State = wallpaper.simulation.state
	_check(state.finished and state.placed_count() == 900 and state.completed_rows == 30, "Exactly 900 bricks finish all 30 rows")
	if not state.finished:
		_check(false, "Completion timed out: " + _describe(wallpaper))
		return
	_check(_placed_tiles(wallpaper.world.pyramid) == 900, "All 900 laid bricks are visible in the scene")
	var old_world: Node = wallpaper.world
	var lighting: Node = wallpaper._light
	var sky = wallpaper._sky
	var completed: Dictionary = wallpaper.simulation.to_dict()
	var deadline: int = wallpaper._restart_at_msec
	_check(deadline >= before_final_tick + 5000 and deadline <= Time.get_ticks_msec() + 5000,
		"Five-second deadline is set by the real completion path")
	await _capture(wallpaper, "finished")
	var hold_samples := 0
	# Avoid crossing the deadline inside _process while checking the old world.
	while Time.get_ticks_msec() < deadline - 50:
		hold_samples += 1
		wallpaper._process(0.01)
		_check(wallpaper.world == old_world and wallpaper.simulation.to_dict() == completed,
			"Completed world and simulation remain frozen during the real hold")
		if failures > 0:
			return
		await create_timer(0.02).timeout
	_check(hold_samples > 0, "Observed the real completed hold")
	while Time.get_ticks_msec() < deadline:
		await process_frame
	wallpaper._process(0.01)
	_check(not is_instance_valid(old_world), "Completed world is freed at reset")
	_check(wallpaper.simulation.to_dict() == fresh, "Reset restores fresh workers, inventory, tasks and counters")
	_check(wallpaper._light == lighting and wallpaper._sky == sky, "Lighting and sky survive reset")
	_check(_scene_counts(wallpaper) == scene_counts and _placed_tiles(wallpaper.world.pyramid) == 0,
		"New world has clean tiles, quarry and node counts")
	_check(_camera_view(wallpaper) == overview, "Overview is preserved on the first reset frame")
	_check(root.get_camera_2d() == wallpaper.world.get_node("Camera2D"), "New camera is active immediately")
	_check(wallpaper.world._effects.values().all(func(sprite): return not sprite.visible) \
		and wallpaper.world._effect_tweens.is_empty(), "Reset has no carried-over effects")
	for frame in range(3):
		await process_frame
		_check(_camera_view(wallpaper) == overview, "Overview remains stable after reset frame %d" % frame)
	print("Completion: 899 -> 900 -> real 5000 ms hold -> clean reset, overview stable")


func _transfer_resume(wallpaper) -> void:
	var state: State = wallpaper.simulation.state
	var view: Dictionary = wallpaper.world._views[PORTER]
	_check(view.transferring and view.facing == -1.0 and view.transfer_after > 0.0 \
		and view.transfer_after < 1.0, "Mid-load leftward approach is reproduced")
	# Reuse both the legacy and current snapshot/visual regression probes.
	_check_transfer_resume(wallpaper, PORTER, true)
	_check_transfer_resume(wallpaper, PORTER)
	var expected: Simulation = Simulation.from_dict(wallpaper._balance, wallpaper.simulation.to_dict())
	var delivered_ids := state.task_resource_ids(PORTER)
	var before: Dictionary = wallpaper.simulation.to_dict()
	var facing: float = view.facing
	var flipped: bool = view.sled.flip_h
	var sled_offset: Vector2 = view.sled.global_position - view.root.global_position
	var item_position: Vector2 = view.transfer_item.global_position
	wallpaper._save_progress()
	wallpaper._resume_cycle()
	wallpaper.world.render_frame(1.0, wallpaper.simulation.elapsed_seconds())
	var after: Dictionary = wallpaper.world._views[PORTER]
	_check(wallpaper.simulation.to_dict() == before, "Real save/resume keeps exact simulation and transfer progress")
	_check(after.facing == facing and after.sled.flip_h == flipped \
		and (after.sled.global_position - after.root.global_position).is_equal_approx(sled_offset) \
		and after.transfer_item.global_position.is_equal_approx(item_position),
		"Real save/resume keeps sled side and hand-carried piece")
	await _capture(wallpaper, "resumed")
	var saw_unload := false
	for tick in range(PLAY_MAX_TICKS):
		expected.step_simulation()
		await _advance(wallpaper)
		_check(wallpaper.simulation.to_dict() == expected.to_dict(), "Resumed transfer matches uninterrupted simulation")
		var phase: StringName = wallpaper.simulation.state.worker(PORTER).fsm_state
		saw_unload = saw_unload or phase == &"unload"
		if saw_unload and phase != &"unload" and wallpaper.simulation.state.stock_count(PORTER) == 0:
			for id in delivered_ids:
				_check(wallpaper.simulation.state.resource_record(id).owner not in [State.Owner.QUARRY, PORTER],
					"Delivered resource %d leaves the quarry and porter" % id)
			print("Transfer resume: legacy/current snapshots, exact continuation through unload and next task")
			return
		if failures > 0:
			return
	_check(false, "Transfer resume timed out: " + _describe(wallpaper))


func _capture(wallpaper, label: String) -> void:
	if not _visual or _capture_dir.is_empty():
		return
	var camera: Camera2D = wallpaper.world.get_node("Camera2D")
	var position_before := camera.position
	var zoom_before := camera.zoom
	if _scenario == "transfer-resume":
		camera.position = wallpaper.world._views[PORTER].after + Vector2(40, -85)
		camera.zoom = Vector2.ONE * 1.5
		camera.force_update_scroll()
	wallpaper.world.render_frame(1.0, wallpaper.simulation.elapsed_seconds())
	await RenderingServer.frame_post_draw
	var path := _capture_dir.path_join("%s-%s.png" % [_scenario, label])
	_check(root.get_texture().get_image().save_png(path) == OK, "Capture " + path)
	print("Captured ", path)
	camera.position = position_before
	camera.zoom = zoom_before
	camera.force_update_scroll()


func _deck_edge(wallpaper) -> float:
	var deck: Sprite2D = wallpaper.world._deck
	return deck.position.x + deck.texture.get_width() * deck.scale.x * 0.5


func _describe(wallpaper) -> String:
	var state: State = wallpaper.simulation.state
	return "tick=%d placed=%d row=%d builder=%s porter=%s" % [
		wallpaper.simulation.to_dict().tick, state.placed_count(), state.current_row,
		state.worker(BUILDER).fsm_state, state.worker(PORTER).fsm_state]
