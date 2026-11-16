extends RefCounted

const Owner = preload("res://scripts/domain/game_state.gd").Owner
const Simulation = preload("res://scripts/simulation/simulation_runner.gd")
const SaveService = preload("res://scripts/application/save_service.gd")
const GameSession = preload("res://scripts/application/game_session.gd")

signal online_events(events: Array[Dictionary])
signal offline_completed(summary: Dictionary)
signal online_tick_completed

enum Mode { ACTIVE, PAUSED, BACKGROUND, RESTORING, UNAVAILABLE }

var mode := Mode.UNAVAILABLE
var session: GameSession
var load_status: SaveService.Status
var tutorial_skipped := false
var _paused := false
var _absence_utc := 0
var _target_ticks := 0
var _remaining_ticks := 0
var _accumulator := 0.0
var _step: float
var _cap: float
var _summary_start: Dictionary


func _init(balance: Dictionary, service: SaveService, now_utc: int) -> void:
	_step = float(balance.simulation.fixedStepSeconds)
	_cap = float(balance.simulation.offlineCapSeconds)
	var loaded := service.load_game()
	load_status = loaded.status
	if load_status not in [SaveService.Status.OK, SaveService.Status.MISSING]:
		return
	var game: Simulation = loaded.simulation if load_status == SaveService.Status.OK else Simulation.new(balance)
	session = GameSession.new(game, service, balance)
	if load_status == SaveService.Status.OK:
		var lifecycle: Dictionary = loaded.lifecycle
		_paused = lifecycle.get("paused", false)
		tutorial_skipped = lifecycle.get("tutorialSkipped", false)
		_absence_utc = lifecycle.get("absenceUtc", loaded.saved_at_utc)
		_target_ticks = lifecycle.get("targetTicks", 0)
		if _absence_utc > 0:
			_begin_restore(now_utc)
			return
	session.lifecycle = _metadata(0, 0)
	_set_mode(Mode.PAUSED if _paused else Mode.ACTIVE)


func set_paused(paused: bool) -> void:
	if mode not in [Mode.ACTIVE, Mode.PAUSED] or paused == _paused:
		return
	_paused = paused
	_set_mode(Mode.PAUSED if paused else Mode.ACTIVE)
	_save_boundary(_absence_utc, 0)


func enter_background(now_utc: int) -> void:
	if mode in [Mode.UNAVAILABLE, Mode.BACKGROUND]:
		return
	if mode != Mode.RESTORING:
		_absence_utc = now_utc
		_save_boundary(_absence_utc, 0)
	_set_mode(Mode.BACKGROUND)


func enter_foreground(now_utc: int) -> void:
	if mode != Mode.BACKGROUND:
		return
	if _target_ticks > 0:
		_set_mode(Mode.RESTORING)
	else:
		_begin_restore(now_utc)


func close(now_utc: int) -> void:
	enter_background(now_utc)
	if mode == Mode.BACKGROUND and _target_ticks == 0:
		session.flush_save()


func advance_frame(delta: float, max_offline_steps: int = 512, budget_usec: int = 3000) -> void:
	if mode == Mode.RESTORING:
		_advance_offline(max_offline_steps, budget_usec)
	elif mode == Mode.ACTIVE and not session.simulation.state.finished:
		_accumulator += delta
		while mode == Mode.ACTIVE and _accumulator >= _step and not session.simulation.state.finished:
			_accumulator -= _step
			var events := session.step_simulation()
			online_tick_completed.emit()
			if not events.is_empty():
				online_events.emit(events)


func interpolation_fraction() -> float:
	if mode != Mode.ACTIVE or session.simulation.state.finished:
		return 1.0
	return clampf(_accumulator / _step, 0.0, 1.0)


func _begin_restore(now_utc: int) -> void:
	_summary_start = _totals()
	_remaining_ticks = _target_ticks
	if _target_ticks == 0:
		var seconds := clampf(float(now_utc - _absence_utc), 0.0, _cap)
		_target_ticks = int(floor(seconds / _step + 1e-9))
		_remaining_ticks = _target_ticks
		session.lifecycle = _metadata(_absence_utc, _target_ticks)
		if _target_ticks > 0:
			session.request_save()
	_set_mode(Mode.RESTORING)


func _advance_offline(max_steps: int, budget_usec: int) -> void:
	var game := session.simulation
	if _remaining_ticks > 0 and not game.state.finished:
		# Persist the fixed limit before processing any part of this absence.
		if session.flush_save() != OK:
			return
		var deadline := Time.get_ticks_usec() + budget_usec
		for index in range(max_steps):
			game.step_simulation()
			_remaining_ticks -= 1
			if _remaining_ticks == 0 or game.state.finished or Time.get_ticks_usec() >= deadline:
				break
		if _remaining_ticks > 0 and not game.state.finished:
			return

	# The new state and consumed absence are published by the same file replacement.
	if _save_boundary(0, 0) != OK:
		return
	var summary := _totals()
	for key in summary:
		summary[key] -= _summary_start[key]
	summary["credited_seconds"] = _target_ticks * _step
	var had_offline_time := _target_ticks > 0
	_absence_utc = 0
	_target_ticks = 0
	_remaining_ticks = 0
	session.lifecycle = _metadata(0, 0)
	_set_mode(Mode.PAUSED if _paused else Mode.ACTIVE)
	if had_offline_time:
		offline_completed.emit(summary)


func _totals() -> Dictionary:
	var game := session.simulation
	var state := game.state
	var delivered := state.mined_count() - state.stock_count(Owner.QUARRY) \
		- state.stock_count(Owner.QUARRY_STOCK) - state.stock_count(Owner.MINER)
	for index in range(state.porter_count):
		var porter_id := Owner.FIRST_PORTER + index
		if state.transfer_source(porter_id) != Owner.WORKSHOP_OUTPUT:
			delivered -= state.stock_count(porter_id)
	return {
		"simulated_seconds": game.elapsed_seconds(),
		"mined": state.mined_count(),
		"layers": state.geometry.quarry_depth(state.mined_count()),
		"delivered": delivered,
		"processed": delivered - state.stock_count(Owner.RAW) - state.stock_count(Owner.DRESSER),
		"placed": state.placed_count(),
		"rows": state.completed_rows,
		"currency": state.currency,
	}


func _metadata(absence_utc: int, target_ticks: int) -> Dictionary:
	return {"paused": _paused, "absenceUtc": absence_utc, "targetTicks": target_ticks, "tutorialSkipped": tutorial_skipped}


func _save_boundary(absence_utc: int, target_ticks: int) -> Error:
	session.lifecycle = _metadata(absence_utc, target_ticks)
	session.request_save()
	return session.flush_save()


func _set_mode(next: Mode) -> void:
	mode = next
	session.purchases.enabled = mode == Mode.ACTIVE


func skip_tutorial() -> void:
	if mode != Mode.ACTIVE or tutorial_skipped:
		return
	tutorial_skipped = true
	_save_boundary(0, 0)
