extends Node

const WallpaperScene = preload("res://scenes/wallpaper.tscn")
const Simulation = preload("res://scripts/simulation/simulation_runner.gd")
const SaveService = preload("res://scripts/application/save_service.gd")
const Blueprint = preload("res://scripts/domain/blueprint.gd")
const LargeBlockChecks = preload("res://tests/blueprint_large_blocks.gd")
const SledChecks = preload("res://tests/sled_cargo.gd")


func _visible_bottom_y(sprite: Sprite2D) -> float:
	var bounds := sprite.texture.get_image().get_used_rect()
	var bottom := float(bounds.end.y) - sprite.texture.get_height() * 0.5
	return sprite.position.y + bottom * absf(sprite.scale.y)


func _ready() -> void:
	var wallpaper = WallpaperScene.instantiate()
	wallpaper.use_temporary_save = true
	add_child(wallpaper)
	wallpaper.set_process(false)
	var balance: Dictionary = wallpaper._balance.duplicate(true)
	var checked := Blueprint.validate({"version": 2, "blocks": LargeBlockChecks.MIXED})
	assert(not checked.has("error"))
	balance.world["blueprintBlocks"] = checked.blocks
	balance.world.pyramidRows = 4
	balance.world.sizePenalty = 1.5
	balance.workers.porter.count = 3
	balance.workers.porter.capacity = 3
	balance.workers.miner["count"] = 2
	balance.workers.dresser["count"] = 2
	balance.workers.builder["count"] = 2
	wallpaper._balance = balance
	wallpaper._save_service = SaveService.new(balance, wallpaper._temporary_save_dir.get_current_dir().path_join("custom-save.json"))
	wallpaper._start_cycle(Simulation.for_wallpaper(balance))
	assert(wallpaper.world._large_brick_sprites.size() == 4)
	assert(wallpaper.world.pyramid.get_used_cells().size() == 2)
	var sled_checks := SledChecks.new()
	sled_checks.check_scaffold_clearance(wallpaper)
	sled_checks.check_mixed_layout(wallpaper)
	var saw_raw_claim := false
	var saw_workshop := false
	var scaffold_captures := {}
	var captured_quarry := false
	for tick in range(100000):
		var events: Array[Dictionary] = wallpaper.simulation.step_simulation()
		wallpaper.world.capture_tick(wallpaper.simulation.state)
		wallpaper.world.play_production(events)
		var state = wallpaper.simulation.state
		var raw: Array = state.stock(Simulation.State.Owner.RAW)
		saw_raw_claim = saw_raw_claim or not state._raw_places.is_empty()
		for index in range(raw.size()):
			var sprite: Sprite2D = wallpaper.world._piles[Simulation.State.Owner.RAW][index]
			assert(sprite.visible)
			assert(is_equal_approx(sprite.position.x, wallpaper.world.screen_point(state.raw_place(raw[index])).x))
			assert(is_equal_approx(_visible_bottom_y(sprite), 0.0))
		var workshop_count: int = state.stock_count(Simulation.State.Owner.WORKSHOP_OUTPUT)
		saw_workshop = saw_workshop or workshop_count > 0
		for index in range(workshop_count):
			var sprite: Sprite2D = wallpaper.world._piles[Simulation.State.Owner.WORKSHOP_OUTPUT][index]
			assert(sprite.visible)
			assert(is_equal_approx(_visible_bottom_y(sprite), 0.0))
		assert(workshop_count + state.incoming_count(Simulation.State.Owner.WORKSHOP_OUTPUT) <= 1)
		assert(state.validate().is_empty())
		await sled_checks.check_frame(wallpaper)
		if not captured_quarry and "--quarry-capture" in OS.get_cmdline_user_args() \
				and state.mined_count() >= 3 and state.stock_count(Simulation.State.Owner.FIRST_PORTER) > 0:
			captured_quarry = true
			var camera: Camera2D = wallpaper.world.get_node("Camera2D")
			var normal_position := camera.position
			var normal_zoom := camera.zoom
			camera.position = wallpaper.world.screen_point(state.geometry.quarry_mouth()) + Vector2(0, -20)
			camera.zoom = Vector2.ONE * 1.35
			camera.force_update_scroll()
			await RenderingServer.frame_post_draw
			var path := OS.get_environment("TEMP").path_join("piramida-quarry-cuts.png")
			assert(wallpaper.get_viewport().get_texture().get_image().save_png(path) == OK)
			camera.position = normal_position
			camera.zoom = normal_zoom
			camera.force_update_scroll()
			print("Captured ", path)
		if "--scaffold-captures" in OS.get_cmdline_user_args():
			var count: int = state.placed_count()
			if count in [3, 4, 5] and not scaffold_captures.has(count) and not state.scaffold_paths.is_empty():
				scaffold_captures[count] = true
				var camera: Camera2D = wallpaper.world.get_node("Camera2D")
				camera.position = wallpaper.world.screen_point(state.worker(state.active_builder_id).position)
				camera.zoom = Vector2.ONE * 1.5
				camera.force_update_scroll()
				await RenderingServer.frame_post_draw
				var path := OS.get_environment("TEMP").path_join("piramida66-scaffold-%d.png" % count)
				assert(wallpaper.get_viewport().get_texture().get_image().save_png(path) == OK)
				print("Captured ", path)
		if wallpaper.simulation.state.finished:
			break
	assert(wallpaper.simulation.state.finished)
	assert(saw_raw_claim and saw_workshop)
	assert(wallpaper.simulation.state.placed_count() == 6)
	assert(wallpaper.simulation.state.stock(Simulation.State.Owner.PLACED) == [0, 1, 2, 3, 4, 5])
	assert(wallpaper.simulation.state.validate().is_empty())
	sled_checks.finish()
	for index in wallpaper.world._large_brick_sprites:
		assert(is_equal_approx(wallpaper.world._large_brick_sprites[index].modulate.a, 1.0))
	assert(wallpaper.world.pyramid.get_used_cells().size() == 2)
	wallpaper.world.render_frame(1.0, wallpaper.simulation.elapsed_seconds())
	print("PASS: mixed-size custom scene, resource identities and two porters")
	get_tree().quit()
