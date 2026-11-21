extends SceneTree

const WALLPAPER := preload("res://scenes/wallpaper.tscn")
const State := preload("res://scripts/domain/game_state.gd")
const Simulation := preload("res://scripts/simulation/simulation_runner.gd")
const SaveService := preload("res://scripts/application/save_service.gd")
const MINER := preload("res://scripts/domain/game_state.gd").Owner.MINER
const BUILDER := preload("res://scripts/domain/game_state.gd").Owner.BUILDER
const PORTER := preload("res://scripts/domain/game_state.gd").Owner.FIRST_PORTER
const DRESSER := preload("res://scripts/domain/game_state.gd").Owner.DRESSER
const Walk := preload("res://scripts/presentation/worker_walk.gd")
const GizaSky := preload("res://scripts/presentation/giza_sky.gd")
const WallpaperSky := preload("res://scripts/presentation/wallpaper_sky.gd")

var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _capture_transfer_frame(wallpaper, filename: String) -> void:
	var camera: Camera2D = wallpaper.world.get_node("Camera2D")
	var view: Dictionary = wallpaper.world._views[PORTER]
	camera.position = view.after + Vector2(40, -85)
	camera.zoom = Vector2.ONE * 1.5
	camera.force_update_scroll()
	wallpaper.world.render_frame(1.0, wallpaper.simulation.elapsed_seconds())
	await RenderingServer.frame_post_draw
	var path := "user://" + filename
	_check(root.get_texture().get_image().save_png(path) == OK, "Capture " + filename)
	print("Captured ", ProjectSettings.globalize_path(path))


func _check_transfer_resume(wallpaper, id: int, legacy: bool = false) -> void:
	var simulation: Simulation = wallpaper.simulation
	var worker := simulation.state.worker(id)
	var view: Dictionary = wallpaper.world._views[id]
	var seconds := simulation.elapsed_seconds()
	wallpaper.world.render_frame(1.0, seconds)
	var item_position: Vector2 = view.transfer_item.global_position
	var sled_offset: Vector2 = view.sled.global_position - view.root.global_position
	var path: String = wallpaper._temporary_save_dir.get_current_dir().path_join("transfer.json")
	var service := SaveService.new(wallpaper._balance, path)
	if legacy:
		_check(service.save_game(simulation) == OK, "Write a snapshot without transfer facing")
	else:
		var original_service: SaveService = wallpaper._save_service
		var next_save_at: float = wallpaper._next_save_at
		var last_saved_rows: int = wallpaper._last_saved_rows
		wallpaper._save_service = service
		wallpaper._save_progress()
		wallpaper._save_service = original_service
		wallpaper._next_save_at = next_save_at
		wallpaper._last_saved_rows = last_saved_rows
	var saved := service.load_game()
	_check(saved.status == SaveService.Status.OK and (saved.has("transfer_facing") != legacy),
		"Read the expected snapshot format for transfer resume")

	var resumed := WALLPAPER.instantiate()
	resumed.use_temporary_save = true
	root.add_child(resumed)
	resumed.set_process(false)
	resumed._save_service = service
	resumed._resume_cycle()
	var restored: State.Worker = resumed.simulation.state.worker(id)
	var next: Dictionary = resumed.world._views[id]
	resumed.world.render_frame(1.0, seconds)
	var next_offset: Vector2 = next.sled.global_position - next.root.global_position
	var next_item: Vector2 = next.transfer_item.global_position
	var label := "tick=%d worker=%d phase=%s source=%d cargo=%d legacy=%s" % [
		roundi(seconds / wallpaper._step), id, worker.fsm_state, simulation.state.transfer_source(id),
		simulation.state.stock_count(id), legacy]
	print("Transfer resume %s work=%s/%s facing=%s/%s sled=%s/%s item=%s/%s" % [
		label, worker.remaining_work, restored.remaining_work, view.facing, next.facing,
		sled_offset, next_offset, item_position, next_item])
	_check(resumed.simulation.to_dict() == simulation.to_dict()
		and restored.fsm_state == worker.fsm_state and restored.remaining_work == worker.remaining_work
		and restored.movement_route().is_empty(), "Restore exact simulation at " + label)
	var transfer_restored: bool = next.transferring and next.transfer_item.visible \
		and next.transfer_after == view.transfer_after and next.transfer_id == view.transfer_id \
		and next.transfer_ground.is_equal_approx(view.transfer_ground)
	# A snapshot without wallpaperTransferFacing cannot reconstruct the approach side
	# after the warehouse route changes; current snapshots must preserve it exactly.
	if not legacy:
		transfer_restored = transfer_restored and next.facing == view.facing \
			and next.sled.flip_h == view.sled.flip_h \
			and next_offset.is_equal_approx(sled_offset) and next_item.is_equal_approx(item_position)
	_check(transfer_restored, "Restore sled and hand-carried piece at " + label)
	resumed.free()
	var camera: Camera2D = wallpaper.world.get_node("Camera2D")
	camera.make_current()
	camera.force_update_scroll()
	wallpaper.world.render_frame(0.0, seconds)


func _check_crank_orbit(world, walker: Walk) -> void:
	var crank: Node2D = world._crank
	var grip: Node2D = world._crank_grip
	var arm := walker._near_arm
	var rotation_before := crank.rotation
	var max_error := 0.0
	var max_contour_step := 0.0
	var valid_contour := true
	var previous := PackedVector2Array()
	# Include the seam between the last sample and the first.
	for degree in range(361):
		crank.rotation = deg_to_rad(degree)
		walker.grip_crank(grip.global_position, true)
		var fist := walker.get_parent().to_global(walker.position + walker.hand_position) as Vector2
		max_error = maxf(max_error, fist.distance_to(grip.global_position))
		valid_contour = valid_contour and not Geometry2D.triangulate_polygon(arm.polygon).is_empty()
		var contour := arm.global_transform * arm.polygon
		if not previous.is_empty():
			for vertex in range(contour.size()):
				max_contour_step = maxf(max_contour_step, contour[vertex].distance_to(previous[vertex]))
		previous = contour
		if degree % 90 == 0:
			_check(arm.visible and arm.texture != null and arm.z_index == 1 and walker._far_arm.visible
				and not walker._crank_arm.visible and not walker._crank_hand.visible,
				"Textured working arm is above the grip, with the resting arm visible")
	_check(max_error <= 0.1, "Crank fist error over the full orbit: %.5f px" % max_error)
	_check(valid_contour, "Textured arm triangulates throughout the crank orbit")
	_check(max_contour_step < 1.0, "Crank contour moves smoothly: %.3f px per degree" % max_contour_step)
	print("Crank orbit: max fist error %.5f px, max contour step %.3f px per degree" % [max_error, max_contour_step])
	crank.rotation = rotation_before
	walker.grip_crank(grip.global_position, true)


func _run() -> void:
	_check_walk_contact()
	var wallpaper := WALLPAPER.instantiate()
	wallpaper.use_temporary_save = true
	root.add_child(wallpaper)
	if wallpaper._temporary_save_dir == null:
		wallpaper.free()
		quit(1)
		return
	var save_dir: String = wallpaper._temporary_save_dir.get_current_dir()
	wallpaper.set_process(false)
	if OS.get_cmdline_user_args().has("--verify-transfer-resume"):
		for tick in range(57):
			wallpaper._process(wallpaper._step)
		_check(wallpaper.world._views[PORTER].transferring
			and wallpaper.world._views[PORTER].facing == -1.0, "Tick 57 reproduces the leftward approach")
		_check_transfer_resume(wallpaper, PORTER, true)
		_check_transfer_resume(wallpaper, PORTER)
		if DisplayServer.get_name() != "headless":
			await _capture_transfer_frame(wallpaper, "transfer-before.png")
			wallpaper._save_progress()
			wallpaper._resume_cycle()
			await _capture_transfer_frame(wallpaper, "transfer-after.png")
		wallpaper.free()
		quit(int(failures > 0))
		return
	if DisplayServer.get_name() != "headless":
		for size in [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(1024, 768)]:
			await _check_window_size(wallpaper, size)
	await process_frame
	_check_sky_transitions(wallpaper)
	_check_torches(wallpaper)
	_check_moon_at_horizon(wallpaper.world)
	_check_idle_poses(wallpaper.world)
	_check_sled_slope(wallpaper.world)
	_check_saved_trip(wallpaper, save_dir.path_join("save.json"))
	_check_quarry_save_migration(wallpaper._balance, save_dir.path_join("quarry-migration.json"))

	var geometry = wallpaper.simulation.state.geometry
	_check(geometry.quarry_count() == 900, "Compact quarry has 900 cells")
	_check(geometry.quarry_excavation.cut(899).has_area(), "The last stone has a quarry cut")
	_check(wallpaper.world._quarry_cut.polygon.is_empty(), "Intact ground has no quarry cut")
	_check(geometry.lift_route(0).is_empty() and not wallpaper.world._platform.visible,
		"Ground row has no lift trip or raised landing")

	var initial: Dictionary = wallpaper.simulation.to_dict()
	var lighting: CanvasModulate = wallpaper._light
	var initial_scene := _scene_counts(wallpaper)
	var camera := _camera_view(wallpaper)
	var transfer_restores := {}
	for cycle in range(1, 3):
		var placements := 0
		var aligned_placements := 0
		var before_tick := 0
		var saw_loaded_builder := false
		var saw_empty_return := false
		var saw_loaded_ascent := false
		var saw_crank := false
		var saw_helper_crank := false
		var returning_operator := -1
		var checked_crank_poses := {}
		var returned_to_step := {}
		var last_struck_layer := -1
		var porter_transfers := {}
		var miner_sled_phases := {}
		var rebuilt_rows := {}
		var mined_before: int = wallpaper.simulation.state.mined_count()
		while not wallpaper.simulation.state.finished and wallpaper.simulation.elapsed_seconds() < 40000.0:
			var before: int = wallpaper.simulation.state.placed_count()
			var deck: Sprite2D = wallpaper.world._deck
			var brick: Sprite2D = wallpaper.world._placing_brick
			var aligned := false
			if brick.visible:
				wallpaper.world.render_frame(1.0, wallpaper.simulation.elapsed_seconds())
				var cell: Vector2i = wallpaper.world._brick_cells[before]
				var pyramid: TileMapLayer = wallpaper.world.pyramid
				aligned = brick.global_position.is_equal_approx(pyramid.to_global(pyramid.map_to_local(cell)))
			before_tick = Time.get_ticks_msec()
			wallpaper._process(wallpaper._step)
			var state: State = wallpaper.simulation.state
			if state.worker(BUILDER).fsm_state == &"rebuild_platform" and not rebuilt_rows.has(state.current_row):
				_check(wallpaper.world._scaffold_root.visible and state.scaffold_paths.size() == (state.current_row >> 1) + 1,
					"Existing scaffold remains visible while changing row %d" % state.current_row)
				rebuilt_rows[state.current_row] = true
			if cycle == 1:
				for id in [PORTER, MINER]:
					var view: Dictionary = wallpaper.world._views[id]
					if view.transferring and view.transfer_after > 0.0 and view.transfer_after < 1.0:
						var source := state.transfer_source(id)
						var intermediate: bool = view.loading and source == State.Owner.QUARRY and state.stock_count(id) > 0
						var key := [id, state.worker(id).fsm_state, source, view.facing, intermediate]
						if not transfer_restores.has(key):
							transfer_restores[key] = true
							_check_transfer_resume(wallpaper, id, true)
							_check_transfer_resume(wallpaper, id)
			var mined := state.mined_count()
			if mined != mined_before:
				_check_quarry_walks(state)
				_check(wallpaper.world._quarry_rim.points.size() >= 4, "The quarry rim follows rectangular cuts")
				mined_before = mined
			var porter: Dictionary = wallpaper.world._views[PORTER]
			if porter.transferring:
				var kind := "load" if porter.loading else "unload"
				var texture: String = porter.transfer_item.texture.resource_path.get_file()
				porter_transfers[kind + "/" + texture] = true
				_check(porter.transfer_item.visible and porter.sled.visible and not porter.tether.visible
					and porter.body.visible and not porter.walker.visible, "Porter handles one piece by hand")
			var miner_phase := state.worker(MINER).fsm_state
			if not miner_sled_phases.has(miner_phase):
				var miner: Dictionary = wallpaper.world._views[MINER]
				match miner_phase:
					&"load", &"unload":
						miner_sled_phases[miner_phase] = miner.sled.visible and miner.transfer_item.visible \
							and not miner.tether.visible and not miner.items[0].visible
						if miner_phase == &"unload":
							var stock_slot: Sprite2D = wallpaper.world._piles[State.Owner.RAW][state.stock_count(State.Owner.RAW)]
							_check(miner.transfer_ground == stock_slot.position, "Miner unloads to the shared raw stockpile")
					&"walk_to_storage":
						if absf(miner.sled.rotation) > 0.02:
							miner_sled_phases[miner_phase] = miner.sled.visible and miner.tether.visible \
								and miner.items[0].visible and miner.items[0].get_parent() == miner.sled \
								and not miner.transfer_item.visible
					&"return_to_quarry":
						miner_sled_phases[miner_phase] = not miner.sled.visible and not miner.transfer_item.visible
			if wallpaper.world._crank.rotation > 0.1:
				var operator: int = wallpaper.simulation.state.lift_operator_id()
				var operator_view: Dictionary = wallpaper.world._views[operator]
				var turning: bool = operator_view.walker.visible and operator_view.walker._near_arm.z_index == 1 \
					and wallpaper.world._rope.visible
				if turning:
					var walker: Walk = operator_view.walker
					var fist: Vector2 = walker.get_parent().to_global(walker.position + walker.hand_position)
					_check(fist.distance_to(wallpaper.world._crank_grip.global_position) <= 0.1,
						"The rendered operator holds the crank")
				if turning and not checked_crank_poses.has(operator):
					_check_crank_orbit(wallpaper.world, operator_view.walker)
					checked_crank_poses[operator] = true
				saw_crank = saw_crank or (operator == BUILDER and turning)
				saw_helper_crank = saw_helper_crank or (operator != BUILDER and turning)
				if turning and operator not in [BUILDER, MINER]:
					returning_operator = operator
			for id in wallpaper.world._views:
				if id == wallpaper.world.Owner.LIFT:
					continue
				var view: Dictionary = wallpaper.world._views[id]
				if view.has("walker") and view.walker.visible:
					if checked_crank_poses.has(id) and not view.cranking and view.walking:
						_check(view.walker._near_arm.z_index == 0, "Stepping restores the normal arm layer")
						returned_to_step[id] = true
					_check(not view.body.visible, "The walk rig replaces the action sprite")
					continue
				var body: Sprite2D = view.body
				var path := body.texture.resource_path
				_check(path.begins_with("res://assets/wallpaper/workers/")
					or (id == MINER and path in ["res://assets/sprites/mine-1.png", "res://assets/sprites/mine-2.png"])
					or ((id == BUILDER or view.get("transferring", false))
						and path == "res://assets/sprites/builder-place.png")
					or (id == DRESSER and path == "res://assets/sprites/dress-idle.png"),
					"Wallpaper workers only use the new frames")
				if id == MINER and path == "res://assets/sprites/mine-1.png":
					var targets: Array[int] = wallpaper.simulation.state.task_resource_ids(MINER)
					last_struck_layer = _check_mine_strike(wallpaper.world, body, targets)
			if not saw_loaded_builder or not saw_empty_return or not saw_loaded_ascent:
				var builder_id: int = wallpaper.world.Owner.BUILDER
				var builder = state.worker(builder_id)
				var view: Dictionary = wallpaper.world._views[builder_id]
				if builder.fsm_state == &"walk_to_brick":
					var sled_loaded: bool = view.sled.visible and view.items[0].visible and view.tether.visible
					saw_loaded_builder = saw_loaded_builder or sled_loaded
					saw_loaded_ascent = saw_loaded_ascent or (sled_loaded and builder.segment_direction().y > 0.0)
				elif builder.fsm_state == &"return_to_platform":
					saw_empty_return = not view.sled.visible and not view.items[0].visible
			var added: int = wallpaper.simulation.state.placed_count() - before
			_check(added in [0, 1], "At most one placement per tick")
			if added == 1:
				var column := before - state.row_start
				var label := "row %d column %d" % [state.current_row, column]
				if state.current_row == 0:
					_check(not deck.visible, "Ground placement has no deck at " + label)
				else:
					var builder := state.worker(BUILDER)
					var route := builder.movement_route()
					if not state.finished:
						_check(builder.fsm_state == &"return_to_platform" and not route.is_empty(),
							"Builder starts the return at " + label)
						if not route.is_empty():
							_check(route[0].is_equal_approx(builder.position),
								"Return starts at the placed surface at " + label)
					_check(not deck.visible and (state.finished or wallpaper.world._scaffold_root.visible),
						"Scaffold remains visible at " + label)
				var cell: Vector2i = wallpaper.world._brick_cells[before]
				var builder_view: Dictionary = wallpaper.world._views[BUILDER]
				_check(wallpaper.simulation.state.stock_count(BUILDER) == 0 and not builder_view.items[0].visible,
					"The builder returns from every completed placement empty.")
				var pyramid: TileMapLayer = wallpaper.world.pyramid
				var surface := pyramid.to_global(pyramid.map_to_local(cell)) - Vector2(0, pyramid.tile_set.tile_size.y * 0.5)
				_check(not brick.visible and pyramid.get_cell_alternative_tile(cell) == 0,
					"The placed tile replaces the moving brick on the completion tick")
				_check(wallpaper.world._effects[&"placement_dust"].global_position.is_equal_approx(surface),
					"Placement dust comes from the completed tile")
				if aligned:
					aligned_placements += 1
			placements += added

		var finished_world: Node = wallpaper.world
		var completed: Dictionary = wallpaper.simulation.to_dict()
		var deadline: int = wallpaper._restart_at_msec
		_check(deadline - before_tick >= 5000 and deadline - Time.get_ticks_msec() <= 5000,
			"Deadline is five seconds after the final tick")
		_check(placements == 900 and wallpaper.simulation.state.finished, "Cycle reached exactly 900 placements")
		_check(rebuilt_rows.size() == 29, "Existing scaffold stays visible for all row transitions")
		_check(aligned_placements == placements, "Every moving brick reaches its final tile before completion")
		_check(last_struck_layer == 29, "Miner strikes through the last quarry layer")
		_check(saw_loaded_builder and saw_empty_return and saw_loaded_ascent,
			"Builder transports a single brick through climb, haul and empty return")
		_check(saw_crank, "Builder's hand follows the crank during a loaded lift trip")
		_check(saw_helper_crank, "An idle worker takes a turn at the crank")
		_check(returned_to_step.has(BUILDER), "Builder returns to walking after cranking")
		if returning_operator >= 0:
			_check(returned_to_step.has(returning_operator), "Temporary helper returns to walking after cranking")
		_check(porter_transfers.has("load/limestone_1x1.png") and porter_transfers.has("unload/limestone_1x1.png"),
			"Porter manually loads and unloads quarry stones")
		if cycle == 1:
			var intermediate_pickup := false
			for facing in [-1.0, 1.0]:
				var intermediate := transfer_restores.has([PORTER, &"load", State.Owner.QUARRY, facing, true])
				intermediate_pickup = intermediate_pickup or intermediate
				_check(intermediate or transfer_restores.has([PORTER, &"load", State.Owner.QUARRY, facing, false]),
					"Restore quarry loading with the porter facing %s" % facing)
				_check(transfer_restores.has([MINER, &"load", State.Owner.QUARRY, facing, false]),
					"Restore the miner loading with facing %s" % facing)
			_check(intermediate_pickup, "Restore a quarry pickup with cargo already on the sled")
		for phase in [&"load", &"walk_to_storage", &"unload", &"return_to_quarry"]:
			_check(miner_sled_phases.get(phase, false), "Miner's sled is correct during %s" % phase)
		_check(_placed_tiles(finished_world.pyramid) == 900, "All 900 bricks replace their outlines")
		_check(wallpaper.simulation.state.validate().is_empty(), "Final ownership and reservations")
		if deadline == 0:
			break
		while Time.get_ticks_msec() < deadline - 50:
			wallpaper._process(0.1)
			_check(wallpaper.world == finished_world, "Completed world remains during hold")
			await process_frame
		_check(wallpaper.simulation.to_dict() == completed, "Simulation frozen during hold")

		# Show transient visuals immediately before reset, even though production has ended.
		var events: Array[Dictionary] = [{"state": &"place_brick", "worker_id": BUILDER, "placement_index": 899}]
		finished_world.play_production(events)
		finished_world.cargo.get_child(0).show()
		while Time.get_ticks_msec() < deadline:
			await process_frame
		wallpaper._process(0.1)
		_check(not is_instance_valid(finished_world), "Old world and its transient visuals freed")
		_check(wallpaper._light == lighting, "Time-of-day lighting persists across cycles")
		_check(wallpaper.simulation.to_dict() == initial, "Fresh tasks, workers, inventory and counters")
		_check(_scene_counts(wallpaper) == initial_scene, "Clean tiles, quarry cut and node counts")
		_check(_placed_tiles(wallpaper.world.pyramid) == 0, "Pyramid reset to outlines")
		_check(_camera_view(wallpaper) == camera, "Same overview and window size")
		_check(root.get_camera_2d() == wallpaper.get_node("World/Camera2D"),
			"New overview camera is active after reset")
		if cycle == 1 and DisplayServer.get_name() != "headless":
			await _check_window_size(wallpaper, Vector2i(1280, 720))
			camera = _camera_view(wallpaper)
		_check(wallpaper.world._effects.values().all(func(sprite): return not sprite.visible)
			and wallpaper.world._effect_tweens.is_empty(), "No effects or tweens carried over")
		_check(wallpaper.world.cargo.get_children().all(func(sprite): return not sprite.visible),
			"No visible stock or quarry cargo")
		for view in wallpaper.world._views.values():
			_check(view.items.all(func(sprite): return not sprite.visible), "No visible worker cargo")

		while wallpaper.simulation.state.mined_count() == 0 and wallpaper.simulation.elapsed_seconds() < 5.0:
			wallpaper._process(wallpaper._step)
		_check(wallpaper.simulation.state.mined_count() == 1, "Next cycle mines its first stone")
		_check(wallpaper.world._quarry_rim.points.size() == 4, "First block opens a rectangular cut in fresh sand")
		print("Cycle %d: %d placements, 5000 ms hold, next first stone at %.1f s, fresh counts %s"
			% [cycle, placements, wallpaper.simulation.elapsed_seconds(), initial_scene])

	wallpaper.free()
	if failures == 0:
		print("PASS: two wallpaper cycles")
	else:
		printerr("FAIL: %d wallpaper cycle checks" % failures)
	quit(int(failures > 0))


func _check_quarry_walks(state: State) -> void:
	var mined := state.mined_count()
	var outline := state.geometry.quarry_slopes.outline(mined)
	if outline.is_empty():
		return
	var excavation := state.geometry.quarry_excavation
	var scaffolds := excavation.scaffold_paths(mined)
	for id in [MINER, PORTER]:
		var worker := state.worker(id)
		if id == PORTER and state.transfer_source(id) != State.Owner.QUARRY:
			continue
		if worker.fsm_state == &"load":
			var targets := state.pickup_targets(id)
			_check(not targets.is_empty() and worker.position.is_equal_approx(
				state.geometry.quarry_pickup(targets[0], mined)), "Loading starts at the stone on the quarry floor")
		var points := PackedVector2Array([worker.position])
		var route := worker.movement_route()
		points.append_array(route)
		for index in range(1, route.size()):
			points.append(route[index - 1].lerp(route[index], 0.5))
		for point in points:
			if point.y >= excavation.terrain_y(point.x) - 0.0001:
				continue
			_check(_on_quarry_scaffold(point, scaffolds), "Quarry routes use the staircase and decks below the terrace")


func _on_quarry_scaffold(point: Vector2, paths: Array[PackedVector2Array]) -> bool:
	for path in paths:
		for index in range(1, path.size()):
			var closest := Geometry2D.get_closest_point_to_segment(point, path[index - 1], path[index])
			if closest.distance_to(point) < 0.0001:
				return true
	return false


func _check_saved_trip(wallpaper: Node2D, path: String) -> void:
	var continuous := Simulation.for_wallpaper(wallpaper._balance) as Simulation
	var state := continuous.state
	var porter := state.worker(PORTER)
	for tick in range(180):
		continuous.step_simulation()
		if porter.fsm_state == &"walk_to_storage" and porter.phase_distance_traveled() > 0.0:
			break
	var pending := state.task_resource_ids(PORTER)
	var destination := State.Owner.RAW
	var saved_at := continuous.elapsed_seconds()
	var remaining := porter.remaining_distance
	var in_flight := porter.fsm_state == &"walk_to_storage" and remaining > 0.0 \
		and state.stock_count(PORTER) > 0 and not pending.is_empty() and state.placed_count() == 0 \
		and state.transfer_source(PORTER) == State.Owner.QUARRY
	_check(in_flight, "Save a loaded porter walk with a reservation before the first placement")
	if not in_flight:
		return

	var service: SaveService = wallpaper._save_service
	_check(service.save_game(continuous) == OK, "Write the active wallpaper trip")
	var primary := service.load_game().get("simulation") as Simulation
	_check(primary != null, "Load the active trip with the wallpaper save service")
	if primary == null:
		return
	var saved := FileAccess.get_file_as_string(path)
	_check(service.save_game(continuous) == OK and FileAccess.get_file_as_string(path + ".bak") == saved,
		"Validate the active trip in both draft files and rotate it to the backup")

	var corrupt := FileAccess.open(path, FileAccess.WRITE)
	_check(corrupt != null, "Open the isolated primary for the backup test")
	if corrupt == null:
		return
	corrupt.store_string("invalid save")
	corrupt.close()
	var backup := service.load_game()
	_check(backup.status == SaveService.Status.OK and backup.get("recovered", false),
		"Recover the active trip from the backup")
	if backup.status != SaveService.Status.OK:
		return
	var recovered: Simulation = backup.simulation
	_check(service.save_game(recovered) == OK and FileAccess.get_file_as_string(path + ".bak") == saved,
		"Replace the invalid primary and preserve the valid backup")

	var restored: Array[Simulation] = [primary, recovered]
	for game in restored:
		_check(game.to_dict() == continuous.to_dict(), "Restored snapshot matches the saved tick")
		var worker := game.state.worker(PORTER)
		_check(worker.fsm_state == porter.fsm_state and worker.remaining_distance == porter.remaining_distance
			and worker.phase_distance_traveled() == porter.phase_distance_traveled(),
			"Restored porter keeps the active phase and distance")
		_check(game.state.task_resource_ids(PORTER) == pending
			and game.state.incoming_count(destination) == state.incoming_count(destination)
			and pending.all(func(id): return game.state.reserved_by(id) == PORTER),
			"Restored porter keeps the ordered reservation and destination slots")

	for tick in range(500):
		var events := continuous.step_simulation()
		var snapshot := continuous.to_dict()
		for game in restored:
			if game.step_simulation() != events or game.to_dict() != snapshot:
				_check(false, "Wallpaper snapshot or transfer order diverged at %.1f s" % continuous.elapsed_seconds())
				return
		if state.placed_count() > 0:
			for game in restored:
				_check(game.state.currency == 0 and game.state.porter_count == 1 and game.state.porter_capacity == 8
					and not game.state.can_add_porter(),
					"Wallpaper still has no economy or extra porter after a placement")
			print("Wallpaper trip: %.1f s, remaining segment %.9f, reserved %s, first brick %d at %.1f s"
				% [saved_at, remaining, pending, state.stock(State.Owner.PLACED)[0], continuous.elapsed_seconds()])
			return
	_check(false, "The restored wallpaper trip reaches the next placement")


func _check_quarry_save_migration(balance: Dictionary, path: String) -> void:
	var previous := balance.duplicate(true)
	previous.world.erase("quarryBlockCuts")
	previous.world.erase("quarrySlopesOnly")
	previous.world.erase("pyramidRamp")
	var legacy := Simulation.for_wallpaper(previous) as Simulation
	var old_service := SaveService.new(previous, path)
	var new_service := SaveService.new(balance, path)
	var cases := {}
	for tick in range(2000):
		legacy.step_simulation()
		if legacy.state.transfer_source(PORTER) != State.Owner.QUARRY:
			continue
		var phase := legacy.state.worker(PORTER).fsm_state
		if cases.has(phase):
			continue
		cases[phase] = true
		_check(old_service.save_game(legacy) == OK, "Write a Windows save using the previous quarry layout")
		var loaded := new_service.load_game()
		_check(loaded.status == SaveService.Status.OK, "Read a Windows save with the previous quarry layout")
		if loaded.status != SaveService.Status.OK:
			continue
		var restored: Simulation = loaded.simulation
		_check(restored.state.to_dict() == legacy.state.to_dict(), "Migration keeps ownership, cargo and reservations")
		_check_quarry_walks(restored.state)
		for id in [MINER, PORTER]:
			var before := legacy.state.worker(id)
			var after := restored.state.worker(id)
			_check(before.fsm_state == after.fsm_state and before.remaining_work == after.remaining_work,
				"Migration keeps the active phase and remaining work")
			var old_length := legacy.state.geometry.route_length(before.movement_route())
			var new_length := restored.state.geometry.route_length(after.movement_route())
			if old_length > 0 and new_length > 0:
				_check(is_equal_approx(before.phase_distance_traveled() / old_length,
					after.phase_distance_traveled() / new_length), "Migration keeps the fraction of the active walk")
		for step in range(100):
			restored.step_simulation()
		_check(restored.state.validate().is_empty(), "The restored quarry trip continues with valid ownership")
		if cases.size() == 4:
			_check(new_service.save_game(restored) == OK, "Save the restored quarry with the current layout")
			var round_trip := new_service.load_game()
			_check(round_trip.status == SaveService.Status.OK and round_trip.simulation.to_dict() == restored.to_dict(),
				"The current save preserves movement and work exactly")
			break
	_check(cases.size() == 4, "Migration covers approach, loading, exit and unloading")


func _check_torches(wallpaper: Node2D) -> void:
	var live_palette: Vector4 = wallpaper._sky.palette
	var torches = wallpaper._torches
	var patrol = wallpaper.world.overseer
	var stands: Array[Node] = torches.get_children()
	var quarry_x: float = wallpaper.world.screen_point(wallpaper.simulation.state.geometry.quarry_mouth()).x
	var expected_x := PackedFloat32Array([quarry_x - 375.0, quarry_x + 10.0, quarry_x + 420.0, 489.0, 883.0])
	_check(stands.size() == expected_x.size(), "There is one torch at each marked site")
	if stands.size() != expected_x.size():
		return
	for index in range(stands.size()):
		_check(stands[index].position.is_equal_approx(Vector2(expected_x[index], 0.0)),
			"Each marked torch stands on the upper terrace")
	wallpaper._sky.palette = GizaSky.palette(Vector2(90.0, 10.0))
	wallpaper._apply_sky()
	for index in range(stands.size()):
		patrol.render(patrol._arrivals[index] + patrol.WATCH_SECONDS + 0.7, false)
	torches._process(1.0)
	for stand in stands:
		_check(not stand.get_node("Flame").visible and not stand.get_node("Light").enabled,
			"Daylight leaves both the flame and the local light off")
	_check_quiet_torch_patrol(patrol, "daylight")

	wallpaper._sky.palette = GizaSky.palette(Vector2(270.0, -6.0))
	wallpaper._apply_sky()
	for index in range(stands.size()):
		var stand := stands[index]
		var arrival: float = patrol._arrivals[index]
		patrol.render(arrival, false)
		patrol.render(arrival + patrol.WATCH_SECONDS + 0.1, false)
		var reaching_hand: Vector2 = patrol._walker.hand_position
		patrol.render(arrival + patrol.WATCH_SECONDS + 0.1, true)
		_check(not reaching_hand.is_equal_approx(patrol._walker.hand_position),
			"The evening patrol reaches for an unlit torch")
		_check(not stand.get_node("Light").enabled, "The torch waits for the tending gesture")
		patrol.render(arrival + patrol.WATCH_SECONDS + 0.7, false)
		torches._process(1.0)
		var light: PointLight2D = stand.get_node("Light")
		_check(stand.get_node("Flame").visible and light.enabled and light.energy > 0.0,
			"The gesture lights the torch and its local light")
		var next_order: float = patrol._arrivals[-1] + arrival + patrol.WATCH_SECONDS + 0.7
		patrol.render(next_order, false)
		var hand_after_skip: Vector2 = patrol._walker.hand_position
		patrol.render(next_order, true)
		_check(hand_after_skip.is_equal_approx(patrol._walker.hand_position),
			"The next patrol stays idle when a frame jump skips the watch phase")
	_check_quiet_torch_patrol(patrol, "night")

	wallpaper._start_cycle()
	_check(torches.get_children() == stands and stands.all(func(stand): return stand.get_node("Light").enabled),
		"The same lit torches survive a construction reset")
	patrol = wallpaper.world.overseer
	wallpaper._sky.palette = GizaSky.palette(Vector2(90.0, -2.0))
	wallpaper._apply_sky()
	for index in range(stands.size()):
		patrol.render(patrol._arrivals[index] + patrol.WATCH_SECONDS + 0.7, false)
	torches._process(1.0)
	for stand in stands:
		_check(not stand.get_node("Flame").visible and not stand.get_node("Light").enabled,
			"The morning patrol extinguishes the flames and turns off their lights")

	wallpaper._sky.palette = live_palette
	wallpaper._apply_sky()


func _check_quiet_torch_patrol(patrol, phase: String) -> void:
	var period: float = patrol._arrivals[-1]
	for cycle in range(1, 3):
		for index in range(patrol._stops.size()):
			var arrival: float = cycle * period + patrol._arrivals[index]
			patrol.render(arrival + 0.1, false)
			var seconds: float = arrival + patrol.WATCH_SECONDS + 0.7
			patrol.render(seconds, false)
			var hand: Vector2 = patrol._walker.hand_position
			patrol.render(seconds, true)
			_check(hand.is_equal_approx(patrol._walker.hand_position),
				"The overseer keeps his hand down on %s patrols at torch %d" % [phase, index])


func _check_sky_transitions(wallpaper: Node2D) -> void:
	var winter := Time.get_unix_time_from_datetime_string("2026-12-21T00:00:00")
	var previous := GizaSky.palette(GizaSky.sun(winter - 60.0, GizaSky.TOMSK))
	for minute in range(1441):
		var palette := GizaSky.palette(GizaSky.sun(winter + minute * 60.0, GizaSky.TOMSK))
		_check(previous.distance_to(palette) < 0.04,
			"Winter sky palette changes smoothly, including low noon and UTC midnight")
		previous = palette

	var live_sky: WallpaperSky = wallpaper._sky
	var sky := WallpaperSky.new()
	wallpaper._sky = sky
	var midnight := Time.get_unix_time_from_datetime_string("2026-11-16T00:00:00")
	sky.update(midnight - 0.5, 100.0)
	var first := sky.celestial
	sky.update(midnight - 0.25, 100.25)
	_check(sky.celestial.sun != first.sun and sky.celestial.moon != first.moon,
		"Sun and Moon move even within a single clock second")
	_check(not first.stars.is_empty() and sky.celestial.stars[0] != first.stars[0],
		"Stars move even within a single clock second")
	sky.update(midnight + 0.25, 100.75)
	_check(sky.celestial_opacity == 1.0 and sky.celestial.sun.distance_to(first.sun) < 0.001,
		"Normal passage through midnight preserves celestial motion")
	var seam := WallpaperSky._interpolate_azimuth(0.99, 0.01, 0.5)
	_check(is_zero_approx(minf(seam, 1.0 - seam)),
		"Motion at the azimuth seam takes the short path")

	var summer_noon := Time.get_unix_time_from_datetime_string("2026-06-21T06:20:00")
	var outgoing := sky.celestial
	var outgoing_palette := sky.palette
	sky.update(summer_noon, 101.0)
	_check(sky.celestial == outgoing and sky.palette == outgoing_palette
		and sky.celestial_opacity == 1.0, "Clock correction starts from the current scene")
	sky.update(summer_noon + 1.0, 102.0)
	_check(sky.celestial == outgoing and is_equal_approx(sky.celestial_opacity, 0.5),
		"Outgoing celestial objects fade before the clock correction moves them")
	wallpaper._apply_sky()
	var light: Color = wallpaper._light.color
	var palette: Vector4 = wallpaper.world._sky_material.get_shader_parameter("palette")
	wallpaper._start_cycle()
	_check(wallpaper._light.color == light
		and wallpaper.world._sky_material.get_shader_parameter("palette") == palette
		and sky.celestial == outgoing, "A construction reset preserves a sky transition")
	sky.update(summer_noon + 2.0, 103.0)
	_check(sky.celestial != outgoing and sky.celestial_opacity == 0.0,
		"Celestial positions resync while transparent")
	sky.update(summer_noon + 3.0, 104.0)
	sky.update(summer_noon + 4.0, 105.0)
	wallpaper._apply_sky()
	_check(sky.palette == Vector4(0.0, 0.0, 1.0, 0.0) and sky.celestial_opacity == 1.0
		and wallpaper.world._sun.visible and not wallpaper.world._stars.visible,
		"Clock correction ends at the new daytime state")
	sky.update(summer_noon + 3604.0, 3705.0)
	_check(sky.palette == Vector4(0.0, 0.0, 1.0, 0.0) and sky.celestial_opacity == 1.0
		and sky._outgoing != null, "A matching system and monotonic sleep gap also resyncs")

	var sun: Sprite2D = wallpaper.world._sun
	wallpaper.world.update_sky(sky.palette, Vector2(0.5, 0.995), PackedVector3Array(), 0.0, 1.0)
	_check(sun.visible and is_equal_approx(sun.self_modulate.a, 0.5),
		"Sun fades in above the horizon")
	wallpaper.world.update_sky(sky.palette, Vector2(0.5, 1.0), PackedVector3Array(), 0.0, 1.0)
	_check(not sun.visible and sun.self_modulate.a == 0.0, "Sun is transparent at the horizon")
	wallpaper._sky = live_sky
	wallpaper._apply_sky()


func _check_moon_at_horizon(world: Node2D) -> void:
	var sprite: Sprite2D = world._moon
	for sample in [
		["07:30", false, 0.0, 0.0],
		["07:40", true, 0.1, 0.9],
		["11:00", true, 1.0, 1.0],
		["14:20", true, 0.8, 0.99],
		["14:30", false, 0.0, 0.0],
	]:
		var utc := Time.get_unix_time_from_datetime_string("2026-11-15T%s:00" % sample[0])
		var lunar := GizaSky.moon(utc, GizaSky.TOMSK)
		var solar := GizaSky.sun(utc, GizaSky.TOMSK)
		world.update_moon(GizaSky.project(lunar), GizaSky.lunar_light(lunar, solar))
		var opacity := sprite.self_modulate.a
		_check(sprite.visible == sample[1] and opacity >= sample[2] and opacity <= sample[3],
			"Tomsk Moon visibility and opacity at %s UTC" % sample[0])


func _check_idle_poses(world: Node2D) -> void:
	var dresser: Dictionary = world._views[DRESSER]
	var porter: Dictionary = world._views[PORTER]
	var walker: Walk = porter.walker
	var phase: float = dresser.rest_material.get_shader_parameter("phase")
	var torso := walker._torso.transform
	var rear_foot := walker._rear[1].transform
	var near_foot := walker._near[1].transform

	world.render_frame(1.0, 0.95)

	_check(dresser.body.visible and dresser.body.material == dresser.rest_material
		and dresser.rest_material.get_shader_parameter("phase") != phase, "Dresser animates while resting")
	_check(walker.visible and walker._torso.transform != torso and not porter.tether.visible,
		"Empty idle porter shifts weight with free hands")
	_check(walker._rear[1].transform == rear_foot and walker._near[1].transform == near_foot,
		"Both feet stay planted during empty idle")
	for facing: float in [-1.0, 1.0]:
		for frame in range(24):
			walker.pose_idle(frame * 0.25, facing)
			for leg in [walker._rear, walker._near]:
				var hip_x: float = (leg[0].polygon[0].x + leg[0].polygon[1].x) * 0.5
				var ankle: Vector2 = leg[1].transform * Walk.ANKLE
				_check(absf(ankle.x - hip_x) <= 2.0, "Idle ankles remain under the hips")
		var planted := [walker._rear[1].transform, walker._near[1].transform]
		for travel: Vector2 in [Vector2.ZERO, Vector2(facing, 0.0)]:
			walker.pose(0.5, travel, facing, false, 0.0)
			_check(walker._rear[1].transform == planted[0] and walker._near[1].transform == planted[1],
				"Stationary and transition poses share the planted stance")
			for leg in [walker._rear, walker._near]:
				var sole: Vector2 = leg[1].transform * Vector2(42, 100)
				var ankle: Vector2 = leg[1].transform * Walk.ANKLE
				var thigh: Vector2 = (leg[0].polygon[0] + leg[0].polygon[1]) * 0.5
				var knee: Vector2 = (leg[0].polygon[2] + leg[0].polygon[3]) * 0.5
				_check(is_zero_approx(sole.y), "Both standing soles meet the surface")
				_check(absf((knee - thigh).angle_to(ankle - knee)) < 0.4,
					"Standing knees stay slightly bent")
	world.render_frame(1.0, 0.0)


func _check_walk_contact() -> void:
	var walker := Walk.new()
	root.add_child(walker)
	walker.scale = Vector2.ONE * 1.25
	for travel: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2(-3, -2).normalized(), Vector2.UP]:
		var facing := -1.0 if travel.x < 0.0 else 1.0
		var climbing := is_zero_approx(travel.x)
		var contact_point := Walk.SOLE if climbing else Walk.TOE
		var stride := travel * Walk.step_length(travel) * walker.scale.y
		for index in range(2):
			var foot: Polygon2D = walker._rear[1] if index == 0 else walker._near[1]
			walker.position = Vector2.ZERO
			walker.pose(index, travel, facing)
			var contact := foot.to_global(contact_point)
			var phases := [0.25, 0.5, 0.75, 0.99] if climbing \
				else [0.25, 0.5, 0.75, 0.8, 0.99, 1.07, 1.13]
			for phase: float in phases:
				walker.position = stride * phase
				walker.pose(index + phase, travel, facing)
				_check(foot.to_global(contact_point).distance_to(contact) < 0.002,
					"The support foot stays planted through its stance")
				if not climbing and phase >= Walk.TOE_ROLL_START:
					var hip := walker._torso.to_global(Walk.HIP)
					_check((contact.x - hip.x) * facing < -4.0,
						"The support toe trails the hip at push-off")
			if not climbing:
				_check(foot.to_global(Walk.SOLE).y < contact.y - 3.0 * walker.scale.y,
					"The heel lifts while the toe supports the worker")
	walker.free()


func _check_mine_strike(world: Node2D, body: Sprite2D, targets: Array[int]) -> int:
	if targets.is_empty():
		_check(false, "A strike needs a reserved stone")
		return -1
	var tip_x := body.texture.get_width() - 73.5 if body.flip_h else 73.5
	var tip := world.to_local(body.to_global(body.offset - body.texture.get_size() * 0.5 + Vector2(tip_x, 78.5)))
	var cell: Vector2i = world._geometry.quarry_grid_cell(targets[0])
	_check(body.flip_h == (world._geometry.quarry_excavation == null and cell.x <= 0) and tip.distance_to(world._quarry_impact_point(targets[0])) < 0.01,
		"The pick tip must touch the exposed edge of the selected cell")
	return cell.y


func _check_sled_slope(world: Node) -> void:
	var view: Dictionary = world._views[PORTER]
	var sled: Sprite2D = view.sled
	var rope: Line2D = view.tether
	view.walker.pose(0.5, Vector2.RIGHT, 1.0, true)
	for travel in [Vector2(2, -1).normalized(), Vector2(-2, -1).normalized(), Vector2.RIGHT]:
		view.tow_direction = travel
		world._update_sled(PORTER, view, true, view.walker)
		var forward := signf(travel.x)
		var hitch_offset := Vector2(forward * 50.0, -11.0).rotated(sled.rotation)
		var hitch := sled.position + hitch_offset
		var hand: Vector2 = view.walker.hand_position
		var original_hitch: Vector2 = -travel * world.PORTER_SLED_DISTANCE + hitch_offset
		_check(is_equal_approx(sled.rotation, (travel * forward).angle())
			and sled.flip_h == (forward < 0.0)
			and rope.get_point_position(0).is_equal_approx(hand)
			and absf(hand.distance_to(hitch) - 3.0 * hand.distance_to(original_hitch)) <= 0.1
			and rope.get_point_position(1).is_equal_approx(hitch),
			"Sled and rope follow the slope in both directions")
	var ascent := PackedVector2Array([Vector2(0, -2), Vector2(4, 0), Vector2(8, 0)])
	world._fit_sled_to_route(sled, ascent, 1, Vector2(430.0, 0.0), 1.0, world.PORTER_SLED_DISTANCE)
	_check(is_equal_approx(sled.rotation, -atan(0.5)) and sled.position.y > 0.0,
		"Sled still follows the ascent when the porter reaches level ground")
	world._fit_sled_to_route(sled, ascent, 1, Vector2(600.0, 0.0), 1.0, world.PORTER_SLED_DISTANCE)
	_check(is_zero_approx(sled.rotation) and sled.position.y <= 0.0,
		"Sled levels out above the surface after both runners leave the slope")
	view.tow_direction = Vector2.RIGHT
	world._update_sled(PORTER, view, false, view.walker)


func _scene_counts(wallpaper: Node) -> Array:
	var world: Node = wallpaper.world
	return [wallpaper.find_children("*", "", true, false).size(),
		world.workers.get_child_count(),
		world._quarry_cut.polygon.size(), world.pyramid.get_used_cells().size()]


func _placed_tiles(layer: TileMapLayer) -> int:
	var count := 0
	for cell in layer.get_used_cells():
		if layer.get_cell_alternative_tile(cell) == 0:
			count += 1
	return count


func _check_window_size(wallpaper: Node, size: Vector2i) -> void:
	root.size = size
	await process_frame
	var world = wallpaper.world
	var canvas := root.get_canvas_transform()
	var viewport_size := root.get_visible_rect().size
	var area: Rect2 = world.wallpaper_sky_area()
	var sky_pixels := canvas * area
	_check(DisplayServer.window_get_size() == size, "Native window reached %s" % size)
	_check(sky_pixels.position.is_equal_approx(Vector2.ZERO)
		and sky_pixels.size.is_equal_approx(viewport_size * Vector2(1.0, 0.67)),
		"Camera and sky cover the resized viewport at %s" % size)
	var frame = wallpaper._sky.celestial
	_check(world._sun.position.is_equal_approx(world._sky_body_position(frame.sun))
		and world._moon.position.is_equal_approx(world._sky_body_position(frame.moon))
		and wallpaper._clouds._sky_area == area, "Sky projections updated on resize at %s" % size)
	print("Window resize checked: %s" % size)


func _camera_view(wallpaper: Node) -> Array:
	var camera: Camera2D = wallpaper.get_node("World/Camera2D")
	return [root.size, camera.position, camera.zoom,
		root.get_canvas_transform(), root.get_final_transform()]


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr(message)
