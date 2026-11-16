extends Node2D

const Lifecycle = preload("res://scripts/application/lifecycle_controller.gd")
const SaveService = preload("res://scripts/application/save_service.gd")
const Simulation = preload("res://scripts/simulation/simulation_runner.gd")
const WorldPresenter = preload("res://scripts/presentation/world_presenter.gd")

const SiteAudio = preload("res://scripts/presentation/site_audio.gd")
const Hud = preload("res://scripts/presentation/hud_presenter.gd")

var lifecycle: Lifecycle
var _balance: Dictionary
var _saves: SaveService
@onready var site_audio: SiteAudio = $Audio
@onready var hud: Hud = $HUD/Control
@onready var world: WorldPresenter = $World


func _ready() -> void:
	_balance = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	_saves = SaveService.new(_balance)
	lifecycle = Lifecycle.new(_balance, _saves, _utc_now())
	if lifecycle.mode == Lifecycle.Mode.UNAVAILABLE:
		push_error("Cannot load game: save status %s" % lifecycle.load_status)
	else:
		world.setup(lifecycle.session.simulation.state, _balance)
		hud.setup(lifecycle, _balance)
		hud.restart_requested.connect(_start_new_game)
		world.worker_selected.connect(hud.select_worker)
		lifecycle.online_tick_completed.connect(_capture_world_tick)
		lifecycle.online_events.connect(site_audio.play_production)
		lifecycle.online_events.connect(world.play_production)
		hud.upgrade_purchased.connect(site_audio.play_upgrade)
		lifecycle.offline_completed.connect(_refresh_world_after_offline)
	get_tree().auto_accept_quit = false
	get_tree().quit_on_go_back = false


func _process(delta: float) -> void:
	if lifecycle.session != null:
		hud.refresh_mode()
	if lifecycle.mode != Lifecycle.Mode.ACTIVE or not hud.blocks_play():
		lifecycle.advance_frame(delta)
	if lifecycle.session != null:
		hud.refresh_mode()
		hud.refresh_flow()
		var state := lifecycle.session.simulation.state
		var active := lifecycle.mode == Lifecycle.Mode.ACTIVE and not state.finished and not hud.blocks_play()
		site_audio.update_transport(state, active, delta)
	if lifecycle.session != null and lifecycle.mode != Lifecycle.Mode.RESTORING:
		world.render_frame(lifecycle.interpolation_fraction(), lifecycle.session.simulation.elapsed_seconds())


func _capture_world_tick() -> void:
	world.capture_tick(lifecycle.session.simulation.state)
	hud.tick()


func _refresh_world_after_offline(summary: Dictionary) -> void:
	world.sync_state(lifecycle.session.simulation.state, true)
	hud.show_offline_report(summary)


func _notification(what: int) -> void:
	if lifecycle == null:
		return
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			lifecycle.enter_background(_utc_now())
		NOTIFICATION_APPLICATION_RESUMED:
			lifecycle.enter_foreground(_utc_now())
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			if not OS.has_feature("mobile"):
				lifecycle.enter_background(_utc_now())
		NOTIFICATION_APPLICATION_FOCUS_IN:
			if not OS.has_feature("mobile"):
				lifecycle.enter_foreground(_utc_now())
		NOTIFICATION_WM_GO_BACK_REQUEST:
			if lifecycle.session != null:
				hud.back()
		NOTIFICATION_WM_CLOSE_REQUEST:
			lifecycle.close(_utc_now())
			get_tree().quit()


func _utc_now() -> int:
	return int(Time.get_unix_time_from_system())


func _start_new_game() -> void:
	var fresh := Simulation.new(_balance)
	var error := _saves.save_game(fresh, {"paused": false, "absenceUtc": 0, "targetTicks": 0})
	if error != OK:
		hud.show_restart_error()
		return
	set_process(false)
	get_tree().reload_current_scene()


func _unhandled_input(event: InputEvent) -> void:
	if lifecycle.session != null and event.is_action_pressed("ui_cancel"):
		hud.back()
		get_viewport().set_input_as_handled()
