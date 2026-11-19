extends RefCounted

const Values = preload("res://scripts/domain/snapshot_values.gd")
const State = preload("res://scripts/domain/game_state.gd")
const QuarryProduction = preload("res://scripts/simulation/quarry_production.gd")

const ConstructionProduction = preload("res://scripts/simulation/construction_production.gd")


var state: State
var _step_seconds: float
var _tick: int = 0
var _last_completion_tick: int = 0
var _production: QuarryProduction
var _construction: ConstructionProduction


static func for_wallpaper(balance: Dictionary) -> RefCounted:
	return new(balance)


func _init(balance: Dictionary, run_production: bool = true) -> void:
	state = State.new(balance)
	_step_seconds = float(balance.simulation.fixedStepSeconds)
	if run_production:
		_production = QuarryProduction.new(state, balance.workers)
		_construction = ConstructionProduction.new(state, balance)
		_production.assign_tasks()


# Boundary commands precede the step. New production tasks advance next tick.
func step_simulation() -> Array[Dictionary]:
	var completed: Array[Dictionary] = []
	if state.finished:
		return completed
	var ids := state.worker_ids()
	ids.sort()
	for worker_id in ids:
		completed.append_array(state.worker(worker_id).advance(_step_seconds))
	_tick += 1
	if not completed.is_empty():
		_last_completion_tick = _tick
	if _production != null:
		for event in completed:
			_production.apply_completion(event)
			_construction.apply_completion(event)
		if state.finished:
			return completed
		_construction.assign_tasks()
		_production.assign_tasks()
		_construction.assign_assistance()
	return completed


func elapsed_seconds() -> float:
	return _tick * _step_seconds


func migrate_quarry_routes() -> bool:
	return _production.migrate_saved_routes()


func migrate_pyramid_routes() -> bool:
	return _construction.migrate_pyramid_routes()


func migrate_workshop_layout() -> void:
	var geometry := state.geometry
	var positions: Dictionary[Vector2, Vector2] = {
		Vector2(3.0, 0.0): geometry.raw_storage(),
		Vector2(5.0, 0.0): geometry.workshop(),
		Vector2(5.48, 0.0): geometry.workshop_pickup(),
	}
	for id in state.worker_ids():
		state.worker(id).relocate_waypoints(positions)


# Debug watchdog. The caller chooses a threshold longer than normal phases.
func stall_diagnostic(after_seconds: float) -> Dictionary:
	var quiet_seconds := (_tick - _last_completion_tick) * _step_seconds
	if _production == null or state.finished or quiet_seconds < after_seconds:
		return {}
	var workers := {}
	for worker_id in state.worker_ids():
		workers[worker_id] = {
			"timing": state.worker(worker_id).timing_snapshot(),
			"reserved": state.task_resource_ids(worker_id),
			"cargo": state.stock(worker_id),
		}
	var buffers := {}
	for owner in [State.Owner.QUARRY, State.Owner.QUARRY_STOCK, State.Owner.RAW, State.Owner.WORKSHOP_OUTPUT,
			State.Owner.FINISHED, State.Owner.PLATFORM]:
		buffers[owner] = {
			"stock": state.stock_count(owner),
			"incoming": state.incoming_count(owner),
			"free": state.free_slots(owner),
		}
	return {"seconds_without_completion": quiet_seconds, "workers": workers,
		"buffers": buffers, "construction_blocked": _construction.blocked_snapshot()}


# Captures timing at a tick boundary for the save layer. Inventory is held by GameState.
func timing_snapshot() -> Dictionary:
	var workers: Array[Dictionary] = []
	var ids := state.worker_ids()
	ids.sort()
	for worker_id in ids:
		workers.append(state.worker(worker_id).timing_snapshot())
	return {"tick": _tick, "step_seconds": _step_seconds, "workers": workers}

func to_dict() -> Dictionary:
	var workers: Array[Dictionary] = []
	var ids := state.worker_ids()
	ids.sort()
	for id in ids:
		workers.append(state.worker(id).to_dict())
	return {
		"tick": _tick, "last_completion_tick": _last_completion_tick,
		"step_seconds": Values.encode_real(_step_seconds), "workers": workers, "model": state.to_dict(),
		"construction_waiting": _construction.waiting_snapshot() if _construction != null else {},
	}


# Populate the candidate before attaching production systems.
static func from_dict(balance: Dictionary, data: Dictionary) -> RefCounted:
	if not Values.integer(data.get("tick"), 9007199254740991) \
			or not Values.integer(data.get("last_completion_tick"), int(data.tick)) \
			or Values.decode_real(data.get("step_seconds")) != float(balance.simulation.fixedStepSeconds) \
			or not data.get("workers") is Array or not data.get("model") is Dictionary:
		return null
	var candidate := new(balance, false)
	if not candidate.state.restore_snapshot(data.model, data.workers, balance):
		return null
	candidate._tick = int(data.tick)
	candidate._last_completion_tick = int(data.last_completion_tick)
	candidate._production = QuarryProduction.new(candidate.state, balance.workers)
	candidate._construction = ConstructionProduction.new(candidate.state, balance)
	if not candidate._construction.restore_routes(data.get("construction_waiting", {})):
		return null
	return candidate



