extends SceneTree

const WallpaperScene = preload("res://scenes/wallpaper.tscn")
const Simulation = preload("res://scripts/simulation/simulation_runner.gd")
const SaveService = preload("res://scripts/application/save_service.gd")


func _initialize() -> void:
	if OS.get_environment("PIRAMIDA_PANEL_TEST") != "1":
		push_error("Set PIRAMIDA_PANEL_TEST=1 and use an isolated APPDATA for this test.")
		quit(2)
		return
	call_deferred("_run")


func _write_json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null)
	file.store_string(JSON.stringify(value))
	file.close()


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null)
	file.store_string(value)
	file.close()


func _test_blueprint_library(wallpaper) -> void:
	const DIRECTORY := "user://wallpaper/blueprints"
	const SELECTION := "user://wallpaper/blueprint-selection.txt"
	const TEXTURES := "user://wallpaper/textures"
	for directory in [DIRECTORY, TEXTURES]:
		assert(DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory)) == OK)
	var raw := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	var finished := Image.create(11, 7, false, Image.FORMAT_RGBA8)
	raw.fill(Color.RED)
	finished.fill(Color.BLUE)
	var raw_hash := "a".repeat(64)
	var finished_hash := "b".repeat(64)
	assert(raw.save_png(TEXTURES.path_join(raw_hash + ".png")) == OK)
	assert(finished.save_png(TEXTURES.path_join(finished_hash + ".png")) == OK)
	var blueprint := {"version": 3, "blocks": [
		{"x": 0, "y": 0, "type": "stone", "size": 1,
			"rawTexture": raw_hash, "finishedTexture": finished_hash},
		{"x": 1, "y": 0, "type": "stone", "size": 2},
	]}
	var original_key: String = wallpaper._profile_key
	var original_time: float = wallpaper.simulation.elapsed_seconds()
	_write_json(DIRECTORY.path_join("b-Красная башня.json"), blueprint)
	_write_json(DIRECTORY.path_join("b-Вторая башня.json"), blueprint)
	_write_text(SELECTION, "b-Красная башня")
	wallpaper._poll_tray_requests()
	var first_key: String = wallpaper._profile_key
	assert(first_key != original_key)
	assert(wallpaper.simulation.state.target_count() == 2)
	assert(wallpaper.simulation.state.geometry.block_size_for_resource(1) == 2)
	var world = wallpaper.world
	assert(world._cargo_texture(0, 1, true).get_image().get_pixel(0, 0) == Color.RED)
	assert(world._cargo_texture(0, 1, false).get_image().get_pixel(0, 0) == Color.BLUE)
	assert(world._cargo_texture(1, 2, true) == world._art["stone_2x2"])
	assert(world._large_brick_sprites[0].texture.get_image().get_pixel(0, 0) == Color.BLUE)
	assert(is_equal_approx(world._large_brick_sprites[0].modulate.a, 0.18))
	for tick in range(10000):
		var events: Array[Dictionary] = wallpaper.simulation.step_simulation()
		world.capture_tick(wallpaper.simulation.state)
		world.play_production(events)
		if wallpaper.simulation.state.placed_count() > 0:
			break
	assert(wallpaper.simulation.state.placed_count() == 1)
	assert(is_equal_approx(world._large_brick_sprites[0].modulate.a, 1.0))
	var first_time: float = wallpaper.simulation.elapsed_seconds()
	_write_text(SELECTION, "b-Вторая башня")
	wallpaper._poll_tray_requests()
	assert(wallpaper._profile_key != first_key)
	assert(is_zero_approx(wallpaper.simulation.elapsed_seconds()))
	_write_text(SELECTION, "b-Красная башня")
	wallpaper._poll_tray_requests()
	assert(wallpaper._profile_key == first_key)
	assert(is_equal_approx(wallpaper.simulation.elapsed_seconds(), first_time))
	_write_text(SELECTION, "default")
	wallpaper._poll_tray_requests()
	assert(wallpaper._profile_key == "")
	assert(wallpaper.simulation.state.target_count() == 900)
	_write_text(SELECTION, "legacy")
	wallpaper._poll_tray_requests()
	assert(wallpaper._profile_key == original_key)
	assert(is_equal_approx(wallpaper.simulation.elapsed_seconds(), original_time))
	assert(DirAccess.remove_absolute(ProjectSettings.globalize_path(SELECTION)) == OK)


func _run() -> void:
	assert(DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://wallpaper")) == OK)
	var wallpaper = WallpaperScene.instantiate()
	root.add_child(wallpaper)
	wallpaper.set_process(false)
	assert(wallpaper._profile_key == "")
	assert(is_equal_approx(wallpaper._time_scale, 1.0))
	_write_text("user://wallpaper/time-scale.txt", "4")
	wallpaper._poll_tray_requests()
	assert(is_equal_approx(wallpaper._time_scale, 4.0))
	var accelerated_from: float = wallpaper.simulation.elapsed_seconds()
	wallpaper._process(0.1)
	assert(is_equal_approx(wallpaper.simulation.elapsed_seconds() - accelerated_from, 0.4))
	_write_text("user://wallpaper/time-scale.txt", "3")
	wallpaper._poll_tray_requests()
	assert(is_equal_approx(wallpaper._time_scale, 1.0))
	_write_text("user://wallpaper/time-scale.txt", "32")
	wallpaper._poll_tray_requests()
	assert(is_equal_approx(wallpaper._time_scale, 32.0))
	var original_speed: float = wallpaper._balance.workers.miner.moveSpeed
	for i in range(50):
		var events: Array[Dictionary] = wallpaper.simulation.step_simulation()
		wallpaper.world.capture_tick(wallpaper.simulation.state)
		wallpaper.world.play_production(events)
	var old_time: float = wallpaper.simulation.elapsed_seconds()
	assert(wallpaper._save_progress())
	var settings := {
		"version": 1, "sizePenalty": 1.5,
		"minerCount": 1, "minerMove": 4.0, "mineSeconds": 3.5,
		"porterCount": 1, "porterEmpty": 3.2, "porterLoaded": 2.8,
		"loadSeconds": 0.5, "unloadSeconds": 0.7,
		"dresserCount": 1, "dresserMove": 3.2, "dressSeconds": 3.0,
		"builderCount": 1, "builderMove": 3.2, "placeSeconds": 2.4,
		"liftBase": 1.5, "liftPerRow": 0.15, "rebuildSeconds": 1.0,
		"weatherMin": 100, "weatherMax": 200, "weatherTransition": 24,
		"clearWeight": 1, "partlyWeight": 1, "cloudyWeight": 1,
	}
	_write_json("user://wallpaper/settings.json", settings)
	wallpaper._reload_panel_data()
	assert(wallpaper._profile_key != "")
	assert(is_equal_approx(wallpaper._balance.workers.miner.moveSpeed, 4.0))
	assert(is_zero_approx(wallpaper.simulation.elapsed_seconds()))
	assert(wallpaper.simulation.state.validate().is_empty())
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://wallpaper/settings.json"))
	wallpaper._reload_panel_data()
	assert(wallpaper._profile_key == "")
	assert(is_equal_approx(wallpaper._balance.workers.miner.moveSpeed, original_speed))
	assert(is_equal_approx(wallpaper.simulation.elapsed_seconds(), old_time))
	var blueprint := {"version": 2, "blocks": [{"x": 0, "y": 0, "type": "stone", "size": 2}]}
	_write_json("user://wallpaper/blueprint.json", blueprint)
	wallpaper._reload_panel_data()
	assert(wallpaper.simulation.state.target_count() == 1)
	assert(wallpaper.simulation.state.geometry.block_size_for_resource(0) == 2)
	assert(wallpaper.simulation.state.validate().is_empty())
	for i in range(50):
		wallpaper.simulation.step_simulation()
	assert(wallpaper.simulation.elapsed_seconds() > 0.0)
	var expected_start: Dictionary = Simulation.for_wallpaper(wallpaper._balance).to_dict()
	var old_world = wallpaper.world
	var request := FileAccess.open("user://wallpaper/reset.request", FileAccess.WRITE)
	assert(request != null)
	request.store_string("panel-test-reset")
	request.close()
	wallpaper._poll_tray_requests()
	assert(not FileAccess.file_exists("user://wallpaper/reset.request"))
	assert(not is_instance_valid(old_world))
	assert(wallpaper.simulation.to_dict() == expected_start)
	assert(wallpaper.simulation.state.placed_count() == 0)
	assert(wallpaper.simulation.state.validate().is_empty())
	var save_path: String = wallpaper._panel_config().save_path
	var primary: Dictionary = wallpaper._save_service.load_game()
	var backup: Dictionary = wallpaper._save_service._read(save_path + ".bak")
	assert(primary.status == SaveService.Status.OK)
	assert(backup.status == SaveService.Status.OK)
	assert(primary.simulation.to_dict() == expected_start)
	assert(backup.simulation.to_dict() == expected_start)
	_test_blueprint_library(wallpaper)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://wallpaper/blueprint.json"))
	wallpaper._reload_panel_data()
	assert(wallpaper._profile_key == "")
	assert(is_equal_approx(wallpaper.simulation.elapsed_seconds(), old_time))
	request = FileAccess.open("user://wallpaper/reset.request", FileAccess.WRITE)
	assert(request != null)
	request.store_string("panel-test-startup")
	request.close()
	wallpaper.free()
	wallpaper = WallpaperScene.instantiate()
	root.add_child(wallpaper)
	wallpaper.set_process(false)
	assert(is_equal_approx(wallpaper._time_scale, 32.0))
	assert(not FileAccess.file_exists("user://wallpaper/reset.request"))
	assert(wallpaper._profile_key == "")
	assert(wallpaper.simulation.to_dict() == Simulation.for_wallpaper(wallpaper._balance).to_dict())
	assert(not wallpaper._extract_panel_files().is_empty())
	assert(FileAccess.file_exists("user://desktop/panel/tools/local-panel/index.html"))
	print("PASS: panel reload, tray speed and reset preserve profiles, apply blueprint, reset both saves and startup")
	quit()
