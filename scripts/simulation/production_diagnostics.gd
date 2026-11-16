extends RefCounted

const State = preload("res://scripts/domain/game_state.gd")
const Owner = State.Owner
const FLOW := ["mined", "delivered", "processed", "lifted", "placed"]

var _window: Array[Dictionary] = []
var _rolling: Dictionary = {}
var _cursor := 0
var _samples := 0
var _step: float
var phase_ticks: Dictionary = {}


func _init(step: float) -> void:
	_step = step
	_window.resize(maxi(1, floori(30.0 / step + 0.000001)))


static func totals(state: State) -> PackedInt32Array:
	var delivered := state.mined_count() - state.stock_count(Owner.QUARRY) \
		- state.stock_count(Owner.QUARRY_STOCK) - state.stock_count(Owner.MINER)
	var bricks_in_transit := 0
	for index in range(state.porter_count):
		var porter_id := Owner.FIRST_PORTER + index
		if state.transfer_source(porter_id) == Owner.WORKSHOP_OUTPUT:
			bricks_in_transit += state.stock_count(porter_id)
		else:
			delivered -= state.stock_count(porter_id)
	if state.worker(Owner.BUILDER).fsm_state in [&"walk_to_lift_base", &"unload_at_lift"]:
		bricks_in_transit += state.stock_count(Owner.BUILDER)
	var processed := delivered - state.stock_count(Owner.RAW) - state.stock_count(Owner.DRESSER)
	return PackedInt32Array([state.mined_count(), delivered, processed,
		processed - state.stock_count(Owner.WORKSHOP_OUTPUT) - bricks_in_transit
			- state.stock_count(Owner.FINISHED) - state.stock_count(Owner.LIFT),
		state.placed_count()])


# Sample at the step boundary, then attach actual production deltas after the step.
func sample(state: State) -> Dictionary:
	var entry := {}
	for worker_id in state.worker_ids():
		var stage: String = _stage(worker_id)
		var phase := String(state.worker(worker_id).fsm_state)
		if phase == "idle":
			phase = _idle_reason(state, stage)
		var key := stage + "/" + phase
		entry[key] = entry.get(key, 0) + 1
	return entry


func record(entry: Dictionary, before: PackedInt32Array, after: PackedInt32Array) -> void:
	for index in range(FLOW.size()):
		if after[index] != before[index]:
			entry[FLOW[index]] = after[index] - before[index]
	for key in _window[_cursor]:
		_rolling[key] -= _window[_cursor][key]
	for key in entry:
		_rolling[key] = _rolling.get(key, 0) + entry[key]
		if "/" in key:
			phase_ticks[key] = phase_ticks.get(key, 0) + entry[key]
	_window[_cursor] = entry
	_cursor = (_cursor + 1) % _window.size()
	_samples = mini(_samples + 1, _window.size())


func rates() -> Dictionary:
	var result := {}
	for key in FLOW:
		result[key] = _rolling.get(key, 0) * 60.0 / maxf(1, _samples) / _step
	return result


func blocked_seconds() -> Dictionary:
	var result := {}
	for key in _rolling:
		if _rolling[key] > 0 and key.get_slice("/", 1) in [
			"quarry_full", "raw_full", "wait_stone", "wait_raw", "brick_full",
			"row_transition", "wait_brick", "base_full", "wait_quarry", "raw_in_transit",
		]:
			result[key] = _rolling[key] * _step
	return result


func limits() -> Dictionary:
	return {
		"miner": _rolling.get("porter/wait_stone", 0),
		"porter": _rolling.get("miner/quarry_full", 0) + _rolling.get("dresser/wait_raw", 0)
			+ _rolling.get("dresser/brick_full", 0),
		"dresser": _rolling.get("porter/raw_full", 0),
		"lift": _rolling.get("lift/lift_brick", 0),
		"builder": _rolling.get("lift/base_full", 0),
	}


func _stage(worker_id: int) -> String:
	match worker_id:
		Owner.MINER: return "miner"
		Owner.DRESSER: return "dresser"
		Owner.LIFT: return "lift"
		Owner.BUILDER: return "builder"
	return "porter"


func _idle_reason(state: State, stage: String) -> String:
	match stage:
		"miner":
			if state.free_slots(Owner.QUARRY) == 0:
				return "quarry_full"
		"porter":
			if state.free_slots(Owner.RAW) == 0:
				return "raw_full"
			return "wait_stone"
		"dresser":
			if state.stock_count(Owner.RAW) == 0:
				return "wait_raw"
			if state.free_slots(Owner.WORKSHOP_OUTPUT) == 0:
				return "brick_full"
		"lift", "builder":
			if state.completed_rows > state.current_row or state.worker(Owner.BUILDER).fsm_state == &"climb_to_platform":
				return "row_transition"
			if stage == "builder" and state.stock_count(Owner.FINISHED) == 0 \
					and state.stock_count(Owner.WORKSHOP_OUTPUT) == 0:
				return "wait_brick"
			if stage == "lift" and state.free_slots(Owner.FINISHED) == 0:
				return "base_full"
	return "idle"

# Diagnose starvation only when the neighboring supply and reservations are known.
func waiting_reasons(state: State) -> Dictionary:
	var entry := sample(state)
	if entry.has("dresser/wait_raw"):
		var reason := "wait_raw"
		if state.free_slots(Owner.WORKSHOP_OUTPUT) == 0:
			reason = "brick_full"
		elif state.incoming_count(Owner.RAW) > 0:
			reason = "raw_in_transit"
		elif state.stock_count(Owner.QUARRY) == 0:
			reason = "wait_quarry"
		entry.erase("dresser/wait_raw")
		entry["dresser/" + reason] = 1
	if state.worker(Owner.BUILDER).fsm_state in [&"rebuild_platform", &"climb_to_platform"]:
		entry["builder/row_transition"] = 1
	return entry


func dominant_wait(stages: Array) -> String:
	var best := ""
	var seconds := 0.0
	for key in blocked_seconds():
		var duration: float = _rolling[key] * _step
		if key.get_slice("/", 0) in stages and duration > seconds:
			best = key.get_slice("/", 1)
			seconds = duration
	return best
