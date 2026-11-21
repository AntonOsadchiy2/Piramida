extends SceneTree

const WallpaperScene = preload("res://scenes/wallpaper.tscn")
const Simulation = preload("res://scripts/simulation/simulation_runner.gd")
const SaveService = preload("res://scripts/application/save_service.gd")
const Blueprint = preload("res://scripts/domain/blueprint.gd")


func _initialize() -> void:
	var wallpaper = WallpaperScene.instantiate()
	wallpaper.use_temporary_save = true
	root.add_child(wallpaper)
	await process_frame
	wallpaper.set_process(false)
	var balance: Dictionary = wallpaper._balance.duplicate(true)
	var checked := Blueprint.validate({"version": 2, "blocks": [
		{"x": 0, "y": 0, "size": 4, "type": "stone"},
		{"x": 4, "y": 0, "size": 2, "type": "stone"},
		{"x": 6, "y": 0, "size": 1, "type": "stone"},
	]})
	assert(not checked.has("error"))
	balance.world["blueprintBlocks"] = checked.blocks
	balance.world.pyramidRows = 1
	wallpaper._balance = balance
	wallpaper._save_service = SaveService.new(balance,
		wallpaper._temporary_save_dir.get_current_dir().path_join("builder-sled-save.json"))
	assert(wallpaper._start_cycle(Simulation.for_wallpaper(balance)))
	for tick in range(100000):
		wallpaper.simulation.step_simulation()
		wallpaper.world.capture_tick(wallpaper.simulation.state)
		var state = wallpaper.simulation.state
		var builder = state.worker(state.active_builder_id)
		var route: PackedVector2Array = builder.movement_route()
		var segment: int = builder.path_segment
		if state.stock_count(builder.id) > 0 and segment + 1 < route.size() \
				and route[segment + 1].y > route[segment].y \
				and builder.remaining_distance > 0.0:
			wallpaper.world.render_frame(1.0, wallpaper.simulation.elapsed_seconds())
			var view: Dictionary = wallpaper.world._views[builder.id]
			assert(not view.tow_route.is_empty(), "Loaded builder must retain the slope route")
			var facing := signf(view.tow_direction.x)
			assert(view.sled.position.x * facing <= -60.0, "Sled must trail the builder horizontally")
			var sled: Sprite2D = view.sled
			var half_width := sled.texture.get_width() * sled.scale.x * 0.5
			var bottom := (sled.texture.get_height() * 0.5 + sled.offset.y) * sled.scale.y
			for index in range(17):
				var local := Vector2(lerpf(-half_width, half_width, float(index) / 16.0), bottom)
				var edge := local.rotated(sled.rotation)
				var x: float = view.root.position.x + sled.position.x + edge.x
				var surface_y: float = wallpaper.world._tow_surface_y(view.tow_route, view.tow_segment, facing, x)
				assert(view.root.position.y + sled.position.y + edge.y <= surface_y + 0.01,
					"Sled runner must stay above the ground and scaffold")
			print("PASS: loaded builder sled follows the slope without entering the ground")
			quit()
			return
		if tick % 32 == 31:
			await process_frame
	push_error("Loaded builder never reached a slope")
	quit(1)
