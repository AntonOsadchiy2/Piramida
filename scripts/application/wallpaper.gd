extends Node2D

const Simulation = preload("res://scripts/simulation/simulation_runner.gd")
const SaveService = preload("res://scripts/application/save_service.gd")
const WorldPresenter = preload("res://scripts/presentation/world_presenter.gd")
const WallpaperSky = preload("res://scripts/presentation/wallpaper_sky.gd")
const WallpaperWeather = preload("res://scripts/application/wallpaper_weather.gd")
const CloudLayer = preload("res://scripts/presentation/cloud_layer.gd")
const SiteTorches = preload("res://assets/wallpaper/torches/site_torches.gd")
const WORLD_SCENE := preload("res://scenes/wallpaper_world.tscn")
const COMPLETED_DISPLAY_MSEC := 5000
const SAVE_PATH := "user://wallpaper/save.json"

var world: WorldPresenter
var simulation: Simulation
var use_temporary_save := false
var _balance: Dictionary
var _step: float
var _accumulator := 0.0
var _restart_at_msec := 0
var _light: CanvasModulate
var _torches: SiteTorches
var _sky := WallpaperSky.new()
var _acceptance := false
var _completed_cycles := 0
var _weather := WallpaperWeather.new()
var _save_service: SaveService
var _temporary_save_dir: DirAccess
var _next_save_at := INF
var _last_saved_rows := 0
@onready var _clouds: CloudLayer = $CloudLayer


static func wallpaper_balance(base: Dictionary) -> Dictionary:
	var effective := base.duplicate(true)
	effective.workers.porter.capacity = Simulation.State.MAX_PORTER_CAPACITY
	var world_config: Dictionary = effective.world
	world_config.quarryCenterX = -5.85
	world_config.quarryStepX = 0.19
	world_config.quarrySlopesOnly = true
	world_config.pyramidRamp = true
	world_config.liftCableClearance = 1.65
	world_config.liftSuspension = 0.50
	return effective


func _ready() -> void:
	_acceptance = OS.get_cmdline_user_args().has("--verify-wallpaper-cycles")
	if OS.has_feature("single_process_wallpaper") and DisplayServer.get_name() != "headless":
		get_window().position = Vector2i(-32000, -32000)
		AudioServer.set_bus_mute(0, true)
		Engine.max_fps = 30
		if not _attach_desktop():
			get_tree().quit(1)
			return
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	_balance = wallpaper_balance(base)
	var save_path := SAVE_PATH
	if _acceptance or use_temporary_save:
		# Keep the handle alive until the scene exits so Godot cleans up the scratch files.
		_temporary_save_dir = DirAccess.create_temp("piramida-wallpaper-")
		if _temporary_save_dir == null:
			push_error("Could not create a temporary directory for wallpaper saves.")
			get_tree().quit(1)
			return
		save_path = _temporary_save_dir.get_current_dir().path_join("save.json")
	_save_service = SaveService.new(_balance, save_path, Simulation.WALLPAPER_ECONOMY_ENABLED)
	_step = float(_balance.simulation.fixedStepSeconds)
	_light = CanvasModulate.new()
	add_child(_light)
	_torches = SiteTorches.new()
	_torches.name = "SiteTorches"
	add_child(_torches)
	if _temporary_save_dir != null:
		_start_cycle()
	else:
		_resume_cycle()


func _resume_cycle() -> void:
	var loaded := _save_service.load_game()
	if loaded.status == SaveService.Status.OK and not loaded.simulation.state.finished:
		_start_cycle(loaded.simulation, loaded.get("transfer_facing", {}))
	else:
		_start_cycle()


func _attach_desktop() -> bool:
	var encoded := FileAccess.get_file_as_string("res://assets/wallpaper/desktop-extension.txt")
	var binary := Marshalls.base64_to_raw(encoded)
	if binary.is_empty():
		push_error("The Windows desktop extension is missing from the export. Build with tools/windows-wallpaper/build.ps1.")
		return false
	var directory := "user://desktop/" + encoded.sha256_text()
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		push_error("Could not create the Windows desktop extension directory: " + directory)
		return false
	var notices := FileAccess.open(directory.path_join("GODOT_NOTICES.txt"), FileAccess.WRITE)
	if notices != null:
		notices.store_string(FileAccess.get_file_as_string("res://assets/wallpaper/desktop-notices.txt"))
		notices.close()
	var library := directory.path_join("DesktopExtension.dll")
	if FileAccess.get_file_as_bytes(library) != binary:
		var temporary := library + ".%d.tmp" % OS.get_process_id()
		var stream := FileAccess.open(temporary, FileAccess.WRITE)
		if stream == null:
			push_error("Could not write the Windows desktop extension: " + temporary)
			return false
		stream.store_buffer(binary)
		var error := stream.get_error()
		stream.close()
		if error == OK:
			error = DirAccess.rename_absolute(temporary, library)
		if error != OK:
			DirAccess.remove_absolute(temporary)
			if FileAccess.get_file_as_bytes(library) != binary:
				push_error("Could not extract the Windows desktop extension: " + error_string(error))
				return false
	var descriptor := directory.path_join("desktop.gdextension")
	var config := ConfigFile.new()
	config.set_value("configuration", "entry_symbol", "piramida_desktop_init")
	config.set_value("configuration", "compatibility_minimum", "4.7")
	config.set_value("libraries", "windows.x86_64", ProjectSettings.globalize_path(library))
	if config.save(descriptor) != OK:
		push_error("Could not save the Windows desktop extension descriptor: " + descriptor)
		return false
	return GDExtensionManager.load_extension(ProjectSettings.globalize_path(descriptor)) \
		== GDExtensionManager.LOAD_STATUS_OK


func _start_cycle(restored: Simulation = null, transfer_facing: Dictionary = {}) -> void:
	var previous_world := world
	simulation = restored if restored != null else Simulation.for_wallpaper(_balance)
	world = WORLD_SCENE.instantiate()
	var camera: Camera2D = world.get_node("Camera2D")
	# Keep the old view active until the new camera has its overview.
	camera.enabled = false
	add_child(world)
	world.setup(simulation.state, _balance, _torches.attach_to_patrol, transfer_facing)
	world.wallpaper_sky_area_changed.connect(_reproject_sky)
	camera.enabled = true
	camera.make_current()
	camera.force_update_scroll()
	if previous_world != null:
		previous_world.free()
		world.name = &"World"
	if _sky.celestial == null:
		_update_sky()
	else:
		_apply_sky()
	_clouds.update_clouds(0.0, world.wallpaper_sky_area(), _weather.cloud_cover)
	_accumulator = 0.0
	_restart_at_msec = 0
	_last_saved_rows = simulation.state.completed_rows
	_next_save_at = simulation.elapsed_seconds() + float(_balance.simulation.autosaveSeconds)
	_save_progress()


func _process(delta: float) -> void:
	_update_sky()
	_weather.advance(delta)
	_clouds.update_clouds(delta, world.wallpaper_sky_area(), _weather.cloud_cover)
	if simulation.state.finished:
		if Time.get_ticks_msec() >= _restart_at_msec:
			if _acceptance:
				_completed_cycles += 1
				print("Verified cycle %d: 900 bricks and 5000 ms hold" % _completed_cycles)
				if _completed_cycles == 2:
					get_tree().quit()
					return
			_start_cycle()
		return

	_accumulator += _step * 256 if _acceptance else minf(delta, 0.25)
	while _accumulator >= _step:
		_accumulator -= _step
		var events := simulation.step_simulation()
		world.capture_tick(simulation.state)
		if simulation.state.completed_rows != _last_saved_rows \
				or simulation.elapsed_seconds() >= _next_save_at \
				or simulation.state.finished:
			_save_progress()
		world.play_production(events)
		if simulation.state.finished:
			if _acceptance and (simulation.state.placed_count() != 900
					or not simulation.state.validate().is_empty()):
				get_tree().quit(1)
				return
			world.render_frame(1.0, simulation.elapsed_seconds())
			_restart_at_msec = Time.get_ticks_msec() + COMPLETED_DISPLAY_MSEC
			return

	world.render_frame(_accumulator / _step, simulation.elapsed_seconds())


func _save_progress() -> void:
	if _save_service == null or simulation == null:
		return
	if _save_service.save_game(simulation, {}, world.transfer_facing_snapshot()) == OK:
		_last_saved_rows = simulation.state.completed_rows
		_next_save_at = simulation.elapsed_seconds() + float(_balance.simulation.autosaveSeconds)


func _notification(what: int) -> void:
	if what in [NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_PAUSED]:
		_save_progress()


func _update_sky() -> void:
	_sky.update(Time.get_unix_time_from_system(), Time.get_ticks_msec() * 0.001)
	_apply_sky()


func _reproject_sky() -> void:
	_apply_sky()
	_clouds.update_clouds(0.0, world.wallpaper_sky_area(), _weather.cloud_cover)


func _apply_sky() -> void:
	var palette := _sky.palette
	_light.color = Color("#506488") * palette.x + Color("#edb49a") * palette.y \
		+ Color.WHITE * palette.z + Color("#ef9d80") * palette.w
	_torches.update_darkness(palette.x)
	_clouds.set_daylight(palette)
	var frame := _sky.celestial
	world.update_sky(palette, frame.sun, frame.stars, frame.star_opacity, _sky.celestial_opacity)
	world.update_moon(frame.moon, frame.lunar_light, _sky.celestial_opacity)
