extends Node2D

const Simulation = preload("res://scripts/simulation/simulation_runner.gd")
const SaveService = preload("res://scripts/application/save_service.gd")
const WorldPresenter = preload("res://scripts/presentation/world_presenter.gd")
const SledMusic = preload("res://scripts/presentation/sled_music.gd")
const WallpaperSky = preload("res://scripts/presentation/wallpaper_sky.gd")
const WallpaperWeather = preload("res://scripts/application/wallpaper_weather.gd")
const Blueprint = preload("res://scripts/domain/blueprint.gd")
const PanelSettings = preload("res://scripts/application/panel_settings.gd")
const CloudLayer = preload("res://scripts/presentation/cloud_layer.gd")
const SiteTorches = preload("res://assets/wallpaper/torches/site_torches.gd")
const WORLD_SCENE := preload("res://scenes/wallpaper_world.tscn")
const COMPLETED_DISPLAY_MSEC := 5000
const MIN_AUTOSAVE_REAL_MSEC := 5000
const SAVE_PATH := "user://wallpaper/save.json"
const LEGACY_BLUEPRINT := "user://wallpaper/blueprint.json"
const BLUEPRINT_SELECTION := "user://wallpaper/blueprint-selection.txt"
const BLUEPRINT_DIRECTORY := "user://wallpaper/blueprints/"
const TIME_SCALE_PATH := "user://wallpaper/time-scale.txt"
const TIME_SCALES := [1, 4, 8, 16, 32]
const TRAY_RELOAD_REQUEST := "user://wallpaper/reload.request"
const PANEL_RESET_REQUEST := "user://wallpaper/reset.request"
const TRAY_OPEN_PANEL_REQUEST := "user://wallpaper/open-panel.request"
const PANEL_URL_FILE := "user://wallpaper/panel-url.txt"
const VERIFY_BLUEPRINT_ARG := "--verify-blueprint"
const PANEL_FILES := [
	"tools/local-panel/server.cjs",
	"tools/local-panel/index.html",
	"data/balance.json",
]

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
var _acceptance_blueprint: Array = []
var _completed_cycles := 0
var _weather := WallpaperWeather.new()
var _sled_music: SledMusic
var _save_service: SaveService
var _temporary_save_dir: DirAccess
var _next_save_at := INF
var _next_timed_save_at_msec := 0
var _last_saved_rows := 0
var _time_scale := 1.0
var _profile_key := ""
var _blueprint_selection := ""
var _panel_pid := -1
var _tray_poll_elapsed := 0.0
var _handled_reset_request := ""
var _failed_reset_request := ""
@onready var _clouds: CloudLayer = $CloudLayer


static func wallpaper_balance(base: Dictionary) -> Dictionary:
	var effective := base.duplicate(true)
	effective.workers.porter.capacity = Simulation.State.MAX_PORTER_CAPACITY
	var world_config: Dictionary = effective.world
	world_config.quarryCenterX = -5.85
	world_config.quarryStepX = 0.19
	world_config.quarryExtraBays = 1
	world_config.quarryUndergroundBays = 8
	world_config.terraceDrop = float(world_config.terraceDrop) * 1.35 * 1.5
	world_config.quarrySlopesOnly = true
	world_config.quarryBlockCuts = true
	world_config.pyramidRamp = true
	world_config.liftCableClearance = 1.65
	world_config.liftSuspension = 0.50
	return effective


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_acceptance = args.has("--verify-wallpaper-cycles")
	if args.has("--verify-panel-resources"):
		var panel_server := _extract_panel_files()
		print("PASS: panel resources in export" if not panel_server.is_empty() else "FAIL: panel resources missing")
		get_tree().quit(0 if not panel_server.is_empty() else 1)
		return
	var blueprint_arg := args.find(VERIFY_BLUEPRINT_ARG)
	if _acceptance and blueprint_arg >= 0:
		var path := args[blueprint_arg + 1] if blueprint_arg + 1 < args.size() else ""
		if path.is_empty() or not FileAccess.file_exists(path):
			set_process(false)
			push_error("--verify-blueprint requires a readable blueprint JSON file.")
			get_tree().quit(1)
			return
		var checked := Blueprint.validate(JSON.parse_string(FileAccess.get_file_as_string(path)))
		if checked.has("error"):
			set_process(false)
			push_error("Invalid verification blueprint: " + checked.error)
			get_tree().quit(1)
			return
		_acceptance_blueprint = checked.blocks
	if OS.has_feature("single_process_wallpaper") and not _acceptance and not use_temporary_save:
		_clear_tray_requests()
	if OS.has_feature("single_process_wallpaper") and DisplayServer.get_name() != "headless":
		get_window().position = Vector2i(-32000, -32000)
		AudioServer.set_bus_mute(0, true)
		Engine.max_fps = 30
		if not _attach_desktop():
			get_tree().quit(1)
			return
	if OS.has_feature("single_process_wallpaper") and not _acceptance and not use_temporary_save:
		_install_bundled_panel_data()
	_apply_panel_config(_panel_config())
	_time_scale = _load_time_scale()
	if _acceptance or use_temporary_save:
		# Keep the handle alive until the scene exits so Godot cleans up the scratch files.
		_temporary_save_dir = DirAccess.create_temp("piramida-wallpaper-")
		if _temporary_save_dir == null:
			push_error("Could not create a temporary directory for wallpaper saves.")
			get_tree().quit(1)
			return
		_save_service = SaveService.new(_balance, _temporary_save_dir.get_current_dir().path_join("save.json"))
	_light = CanvasModulate.new()
	add_child(_light)
	_torches = SiteTorches.new()
	_torches.name = "SiteTorches"
	add_child(_torches)
	if _temporary_save_dir != null:
		if not _start_cycle() and _acceptance:
			set_process(false)
			get_tree().quit(1)
	elif not _handle_reset_request():
		_resume_cycle()
	if not _acceptance and not use_temporary_save and DisplayServer.get_name() != "headless":
		_sled_music = SledMusic.new()
		add_child(_sled_music)


func _panel_config() -> Dictionary:
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	var balance := wallpaper_balance(base)
	var save_path := SAVE_PATH
	var profile_key := ""
	var custom := _acceptance_blueprint
	var selection := ""
	var settings: Dictionary = {}
	if not _acceptance and not use_temporary_save:
		selection = _read_blueprint_selection()
		custom = _load_blueprint(selection)
		settings = _load_settings()
		if not settings.is_empty():
			PanelSettings.apply(balance, settings)
		if not custom.is_empty() or not settings.is_empty():
			var profile := {"blueprint": custom, "settings": settings}
			if not custom.is_empty() and selection.begins_with("b-"):
				profile["selection"] = selection
			profile_key = JSON.stringify(profile, "", true).sha256_text()
			save_path = "user://wallpaper/profiles/" + profile_key + "/save.json"
	if not custom.is_empty():
		balance.world["blueprintBlocks"] = custom
		var levels := {}
		for block in custom:
			levels[int(block.y)] = true
		balance.world.pyramidRows = levels.size()
	return {"balance": balance, "settings": settings, "save_path": save_path,
		"key": profile_key, "selection": selection}


func _apply_panel_config(config: Dictionary) -> void:
	_balance = config.balance
	_profile_key = config.key
	_blueprint_selection = config.get("selection", "")
	_weather = WallpaperWeather.new()
	if not config.settings.is_empty():
		_weather.configure(config.settings)
	_save_service = SaveService.new(_balance, config.save_path)
	_step = float(_balance.simulation.fixedStepSeconds)


func _reload_panel_data() -> void:
	if _acceptance or use_temporary_save:
		return
	var config := _panel_config()
	if config.key == _profile_key:
		_blueprint_selection = config.selection
		return
	if not _save_progress():
		push_warning("Panel reload cancelled because progress could not be saved.")
		return
	_apply_panel_config(config)
	_resume_cycle()


func _load_settings() -> Dictionary:
	const PATH := "user://wallpaper/settings.json"
	if not FileAccess.file_exists(PATH):
		return {}
	var result := PanelSettings.validate(JSON.parse_string(FileAccess.get_file_as_string(PATH)))
	if result.is_empty():
		push_warning("Ignoring invalid panel settings.")
	return result


func _read_blueprint_selection() -> String:
	if not FileAccess.file_exists(BLUEPRINT_SELECTION):
		return "legacy" if FileAccess.file_exists(LEGACY_BLUEPRINT) else "default"
	var selection := FileAccess.get_file_as_string(BLUEPRINT_SELECTION)
	if selection in ["default", "legacy"]:
		return selection
	if selection.begins_with("b-") and selection.length() > 2 and selection.length() <= 62 \
			and selection == selection.validate_filename():
		return selection
	return "default"


func _load_blueprint(selection: String) -> Array:
	if selection == "default":
		return []
	var path := LEGACY_BLUEPRINT if selection == "legacy" else BLUEPRINT_DIRECTORY + selection + ".json"
	if not FileAccess.file_exists(path):
		return []
	var checked := Blueprint.validate(JSON.parse_string(FileAccess.get_file_as_string(path)))
	if checked.has("error"):
		push_warning("Ignoring invalid blueprint: " + checked.error)
		return []
	return checked.blocks


func _load_time_scale() -> float:
	if _acceptance or use_temporary_save or not FileAccess.file_exists(TIME_SCALE_PATH):
		return 1.0
	var text := FileAccess.get_file_as_string(TIME_SCALE_PATH).strip_edges()
	if not text.is_valid_int():
		return 1.0
	var value := text.to_int()
	return float(value) if value in TIME_SCALES else 1.0


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


func _start_cycle(restored: Simulation = null, transfer_facing: Dictionary = {}, reset_progress := false) -> bool:
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
	return _save_progress(reset_progress)


func _reset_panel_progress() -> bool:
	if _acceptance or use_temporary_save:
		return false
	var config := _panel_config()
	if config.key != _profile_key and simulation != null and not _save_progress():
		push_warning("Panel reset cancelled because previous profile could not be saved.")
		return false
	_apply_panel_config(config)
	return _start_cycle(null, {}, true)


func _handle_reset_request() -> bool:
	if not FileAccess.file_exists(PANEL_RESET_REQUEST):
		return false
	var request_id := FileAccess.get_file_as_string(PANEL_RESET_REQUEST).strip_edges()
	if request_id.is_empty() or request_id == _failed_reset_request:
		return false
	if request_id == _handled_reset_request:
		return true
	if not _reset_panel_progress():
		_failed_reset_request = request_id
		return false
	_handled_reset_request = request_id
	var result := DirAccess.remove_absolute(ProjectSettings.globalize_path(PANEL_RESET_REQUEST))
	if result != OK:
		push_warning("Could not clear panel reset request: " + error_string(result))
	return true


func _clear_tray_requests() -> void:
	for request in [TRAY_RELOAD_REQUEST, TRAY_OPEN_PANEL_REQUEST]:
		if FileAccess.file_exists(request):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(request))


func _poll_tray_requests() -> void:
	_time_scale = _load_time_scale()
	if _handle_reset_request():
		if FileAccess.file_exists(TRAY_RELOAD_REQUEST):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TRAY_RELOAD_REQUEST))
	elif FileAccess.file_exists(TRAY_RELOAD_REQUEST) or _read_blueprint_selection() != _blueprint_selection:
		if FileAccess.file_exists(TRAY_RELOAD_REQUEST):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TRAY_RELOAD_REQUEST))
		_reload_panel_data()
	if FileAccess.file_exists(TRAY_OPEN_PANEL_REQUEST):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TRAY_OPEN_PANEL_REQUEST))
		_open_panel()


func _install_bundled_panel_data() -> void:
	const DIRECTORY := "user://wallpaper/"
	const MARKER := DIRECTORY + ".bundled-panel-v1"
	if FileAccess.file_exists(MARKER):
		return
	var new_profile := not DirAccess.dir_exists_absolute(DIRECTORY)
	var archive := ZIPReader.new()
	if archive.open("res://data/panel-defaults.zip") != OK:
		push_warning("Could not open the bundled panel data.")
		return
	for relative_path in archive.get_files():
		if relative_path == "settings.json":
			if not new_profile:
				continue
		else:
			var filename := relative_path.get_file()
			if relative_path.get_base_dir() not in ["blueprints", "block-presets", "textures"] \
					or filename in ["", ".", ".."] or filename != filename.validate_filename():
				push_warning("Unexpected bundled panel path: " + relative_path)
				return
		var destination := DIRECTORY + relative_path
		if not FileAccess.file_exists(destination) \
				and not _write_bundled_panel_file(destination, archive.read_file(relative_path)):
			push_warning("Could not install bundled panel data: " + relative_path)
			return
	archive.close()
	var marker := FileAccess.open(MARKER, FileAccess.WRITE)
	if marker == null:
		push_warning("Could not mark the bundled panel data as installed.")


func _write_bundled_panel_file(destination: String, content: PackedByteArray) -> bool:
	if content.is_empty() or DirAccess.make_dir_recursive_absolute(destination.get_base_dir()) != OK:
		return false
	var scratch := destination + ".bundled.tmp"
	var file := FileAccess.open(scratch, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(content)
	var error := file.get_error()
	file.close()
	if error == OK and DirAccess.rename_absolute(scratch, destination) == OK:
		return true
	DirAccess.remove_absolute(scratch)
	return false


func _extract_panel_files() -> String:
	for relative_path in PANEL_FILES:
		var source: String = "res://" + relative_path
		var destination: String = "user://desktop/panel/" + relative_path
		var content := FileAccess.get_file_as_bytes(source)
		if content.is_empty():
			push_error("Panel file is missing from the export: " + source)
			return ""
		if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(destination.get_base_dir())) != OK:
			push_error("Could not create panel directory: " + destination.get_base_dir())
			return ""
		if FileAccess.file_exists(destination) and FileAccess.get_file_as_bytes(destination) == content:
			continue
		var file := FileAccess.open(destination, FileAccess.WRITE)
		if file == null:
			push_error("Could not write panel file: " + destination)
			return ""
		file.store_buffer(content)
		var error := file.get_error()
		file.close()
		if error != OK:
			push_error("Could not write panel file: " + destination)
			return ""
	return ProjectSettings.globalize_path("user://desktop/panel/tools/local-panel/server.cjs")


func _find_node_path() -> String:
	var directories := OS.get_environment("PATH").split(";", false)
	if OS.has_environment("ProgramFiles"):
		directories.append(OS.get_environment("ProgramFiles").path_join("nodejs"))
	for directory in directories:
		var candidate := directory.strip_edges().trim_prefix('"').trim_suffix('"').path_join("node.exe")
		if FileAccess.file_exists(candidate):
			return candidate
	return ""


func _open_panel() -> void:
	if _panel_pid > 0 and OS.is_process_running(_panel_pid):
		if FileAccess.file_exists(PANEL_URL_FILE):
			var url := FileAccess.get_file_as_string(PANEL_URL_FILE).strip_edges()
			if url.begins_with("http://127.0.0.1:"):
				OS.shell_open(url)
		return
	var node_path := _find_node_path()
	if node_path.is_empty():
		OS.alert("Для локальной панели установите Node.js и добавьте node.exe в PATH.", "Пирамида")
		return
	var server_path := _extract_panel_files()
	if server_path.is_empty():
		OS.alert("Не удалось извлечь файлы локальной панели.", "Пирамида")
		return
	if FileAccess.file_exists(PANEL_URL_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PANEL_URL_FILE))
	_panel_pid = OS.create_process(node_path, PackedStringArray([
		server_path, "--open", "--url-file", ProjectSettings.globalize_path(PANEL_URL_FILE)
	]))
	if _panel_pid < 0:
		OS.alert("Не удалось запустить локальную панель.", "Пирамида")


func _process(delta: float) -> void:
	if not _acceptance and not use_temporary_save:
		_tray_poll_elapsed += delta
		if _tray_poll_elapsed >= 0.25:
			_tray_poll_elapsed = 0.0
			_poll_tray_requests()
	_update_sky()
	_weather.advance(delta)
	_clouds.update_clouds(delta, world.wallpaper_sky_area(), _weather.cloud_cover)
	if simulation.state.finished:
		if Time.get_ticks_msec() >= _restart_at_msec:
			var placements := simulation.state.placed_count()
			var restarted := _start_cycle()
			if _acceptance:
				if not restarted or simulation.state.placed_count() != 0 or simulation.state.finished \
						or simulation.state.target_count() != placements or not simulation.state.validate().is_empty():
					push_error("Wallpaper verification failed to reset the construction.")
					get_tree().quit(1)
					return
				_completed_cycles += 1
				print("Verified cycle %d: %d bricks and %d ms hold" % [
					_completed_cycles, placements, COMPLETED_DISPLAY_MSEC])
				if _completed_cycles == 2:
					get_tree().quit()
		return

	_accumulator += _step * 256 if _acceptance else minf(delta, 0.25) * _time_scale
	while _accumulator >= _step:
		_accumulator -= _step
		var events := simulation.step_simulation()
		world.capture_tick(simulation.state)
		var timed_save_due := simulation.elapsed_seconds() >= _next_save_at \
				and Time.get_ticks_msec() >= _next_timed_save_at_msec
		if simulation.state.completed_rows != _last_saved_rows \
				or timed_save_due \
				or simulation.state.finished:
			_save_progress()
		world.play_production(events)
		if simulation.state.finished:
			if _acceptance and (simulation.state.placed_count() != simulation.state.target_count()
					or not simulation.state.validate().is_empty()):
				get_tree().quit(1)
				return
			world.render_frame(1.0, simulation.elapsed_seconds())
			_restart_at_msec = Time.get_ticks_msec() + COMPLETED_DISPLAY_MSEC
			return

	var sled_jump := _sled_music.jump_height(delta) if _sled_music != null else 0.0
	world.render_frame(_accumulator / _step, simulation.elapsed_seconds(), sled_jump)


func _save_progress(reset_progress := false) -> bool:
	if _save_service == null or simulation == null:
		return false
	var result := _save_service.save_game(simulation, {}, world.transfer_facing_snapshot(), reset_progress)
	if result != OK:
		push_warning("Could not save wallpaper progress: " + error_string(result))
		return false
	_last_saved_rows = simulation.state.completed_rows
	_next_save_at = simulation.elapsed_seconds() + float(_balance.simulation.autosaveSeconds)
	_next_timed_save_at_msec = Time.get_ticks_msec() + MIN_AUTOSAVE_REAL_MSEC
	return true


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
