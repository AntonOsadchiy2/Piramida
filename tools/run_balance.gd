extends SceneTree

const Simulation = preload("res://scripts/simulation/simulation_runner.gd")
const State = preload("res://scripts/domain/game_state.gd")
const Owner = State.Owner
const Diagnostics = preload("res://scripts/simulation/production_diagnostics.gd")
const SaveService = preload("res://scripts/application/save_service.gd")
const Lifecycle = preload("res://scripts/application/lifecycle_controller.gd")
const TRANSPORT := ["HIRE_PORTER", "PORTER_SPEED", "PORTER_CAPACITY"]
const ALL := ["MINER_SPEED", "DRESSER_SPEED", "BUILDER_SPEED",
	"HIRE_PORTER", "PORTER_SPEED", "PORTER_CAPACITY"]
const BY_STAGE := {
	"miner": ["MINER_SPEED"], "porter": TRANSPORT,
	"dresser": ["DRESSER_SPEED"], "builder": ["BUILDER_SPEED"], "lift": [],
}
const SCENARIOS := ["none", "even", "transport", "mining", "bottleneck", "reload", "offline", "second_porter"]
const CHECKPOINT_SECONDS := 300.0
const OFFLINE_SECONDS := 14400
const START_UTC := 1800000000

var _balance: Dictionary
var _step: float
var _output: String
var _baseline: Dictionary
var _reference_trace: Array[Dictionary] = []
var _summary: FileAccess
var _phases: FileAccess
var _purchases: FileAccess


func _initialize() -> void:
	quit(0 if _run() else 1)


func _run() -> bool:
	var args := OS.get_cmdline_user_args()
	if args.size() < 1 or args.size() > 2 or not args[0].is_absolute_path():
		return _fail("Usage: --script res://tools/run_balance.gd -- ABSOLUTE_OUTPUT_DIR [BALANCE_JSON]")
	_output = args[0]
	var config: Variant = JSON.parse_string(FileAccess.get_file_as_string(
		args[1] if args.size() == 2 else "res://data/balance.json"))
	if not config is Dictionary:
		return _fail("Cannot read balance JSON")
	_balance = config
	_step = float(_balance.simulation.fixedStepSeconds)
	if DirAccess.make_dir_recursive_absolute(_output) != OK:
		return _fail("Cannot create output directory")
	_summary = FileAccess.open(_output.path_join("summary.csv"), FileAccess.WRITE)
	_phases = FileAccess.open(_output.path_join("phases.csv"), FileAccess.WRITE)
	_purchases = FileAccess.open(_output.path_join("purchases.csv"), FileAccess.WRITE)
	if not _summary or not _phases or not _purchases:
		return _fail("Cannot open CSV files")
	_csv(_summary, ["scenario", "simSeconds", "firstBrick", "mined100", "mined400",
		"placed100", "placed400", "mined900", "delivered900", "processed900", "lifted900",
		"placed900", "coins", "porters", "reloads", "offlineCreditedSeconds"])
	_csv(_phases, ["scenario", "stage", "phaseOrReason", "workerSeconds"])
	_csv(_purchases, ["scenario", "simTime", "upgrade", "price", "newLevel"])
	for scenario in SCENARIOS:
		if not _run_scenario(scenario):
			return false
	for file in [_summary, _phases, _purchases]:
		file.flush()
		if file.get_error() != OK:
			return _fail("Cannot finish writing CSV")
		file.close()
	return true


func _run_scenario(scenario: String) -> bool:
	var trace := FileAccess.open(_output.path_join(scenario + ".csv"), FileAccess.WRITE)
	if not trace:
		return _fail("Cannot open trace for " + scenario)
	_csv(trace, ["simTime", "mined", "delivered", "processed", "placed", "coins", "activePorters",
		"upgradeLevels", "quarryQueue", "rawStock", "brickStock", "platformStock", "currentLayer",
		"currentRow", "portersOnTrip", "ratesPerMinute", "blockedWorkerSeconds", "limitationScores"])
	var game := Simulation.new(_balance)
	var diagnostics := Diagnostics.new(_step)
	var save_path := _output.path_join(".balance-%d-%d.json" % [OS.get_process_id(), Time.get_ticks_usec()])
	var service := SaveService.new(_balance, save_path)
	var lifecycle: Lifecycle
	var offline := {"credited_seconds": 0.0}
	if scenario == "offline":
		lifecycle = Lifecycle.new(_balance, service, START_UTC)
		lifecycle.offline_completed.connect(func(summary: Dictionary) -> void:
			offline.credited_seconds = summary.credited_seconds)
		game = lifecycle.session.simulation
		lifecycle.enter_background(START_UTC)
		lifecycle.enter_foreground(START_UTC + OFFLINE_SECONDS)
		if lifecycle.mode != Lifecycle.Mode.RESTORING:
			return _fail("Could not start offline restoration")
	var checkpoints := 0
	var reloads := 0
	var next_checkpoint := CHECKPOINT_SECONDS
	var milestones := {}
	var totals := Diagnostics.totals(game.state)
	var next_sample := 30.0
	_write_trace(trace, game, totals, diagnostics)
	while not game.state.finished:
		var elapsed := game.elapsed_seconds()
		if elapsed >= 8 * 3600 or not game.stall_diagnostic(300.0).is_empty():
			return _fail("Production stalled or exceeded 8h in " + scenario)
		var code := _choose(scenario, game, diagnostics)
		if not code.is_empty():
			var level := game.economy.purchase_level(game.state, code)
			var price := game.economy.next_price(game.state, code)
			if not game.economy.try_purchase(game.state, code, level):
				return _fail("Purchase failed in " + scenario)
			_csv(_purchases, [scenario, elapsed, code, price, level + 1])
		var entry := diagnostics.sample(game.state)
		if lifecycle and lifecycle.mode == Lifecycle.Mode.RESTORING:
			lifecycle.advance_frame(0, 1)
			if game.elapsed_seconds() == elapsed or lifecycle.session.last_save_error != OK:
				return _fail("Offline restoration stopped")
		else:
			game.step_simulation()
		var after := Diagnostics.totals(game.state)
		elapsed = game.elapsed_seconds()
		diagnostics.record(entry, totals, after)
		for index in range(after.size()):
			for threshold in ([1, 100, 400, 900] if index == 0 or index == 4 else [900]):
				if totals[index] < threshold and after[index] >= threshold:
					milestones[Diagnostics.FLOW[index] + str(threshold)] = elapsed
		totals = after
		if elapsed >= next_checkpoint or game.state.finished:
			var snapshot := game.to_dict()
			if scenario == "none":
				_reference_trace.append(snapshot)
			elif scenario in ["reload", "offline"]:
				if checkpoints >= _reference_trace.size() or snapshot != _reference_trace[checkpoints]:
					return _fail("Reference mismatch in %s at %.1fs" % [scenario, elapsed])
			if scenario == "reload" and elapsed >= next_checkpoint:
				if service.save_game(game) != OK:
					return _fail("Checkpoint write failed")
				var loaded := service.load_game()
				if loaded.status != SaveService.Status.OK or loaded.simulation.to_dict() != snapshot:
					return _fail("Checkpoint round trip failed")
				game = loaded.simulation
				reloads += 1
			checkpoints += 1
			next_checkpoint += CHECKPOINT_SECONDS
		if elapsed >= next_sample or game.state.finished:
			var errors := game.state.validate()
			if not errors.is_empty():
				return _fail(str(errors))
			_write_trace(trace, game, totals, diagnostics)
			next_sample += 30.0
	if scenario == "none":
		_baseline = game.to_dict()
	if scenario in ["reload", "offline"] and game.to_dict() != _baseline:
		return _fail("Final snapshot mismatch in " + scenario)
	if lifecycle and (lifecycle.mode != Lifecycle.Mode.ACTIVE or offline.credited_seconds != OFFLINE_SECONDS):
		return _fail("Offline restoration did not commit its full allowance")
	for suffix in ["", ".bak"]:
		if FileAccess.file_exists(save_path + suffix) and DirAccess.remove_absolute(save_path + suffix) != OK:
			return _fail("Cannot remove scenario save")
	var state := game.state
	_csv(_summary, [scenario, game.elapsed_seconds(), milestones.placed1, milestones.mined100,
		milestones.mined400, milestones.placed100, milestones.placed400, milestones.mined900,
		milestones.delivered900, milestones.processed900, milestones.lifted900, milestones.placed900,
		state.currency, state.porter_count, reloads, offline.credited_seconds])
	var keys := diagnostics.phase_ticks.keys()
	keys.sort()
	for key: String in keys:
		var parts := key.split("/")
		_csv(_phases, [scenario, parts[0], parts[1], diagnostics.phase_ticks[key] * _step])
	trace.flush()
	if trace.get_error() != OK:
		return _fail("Cannot finish trace for " + scenario)
	trace.close()
	print("%s: %.1fs, %d bricks" % [scenario, game.elapsed_seconds(), state.placed_count()])
	return true


func _choose(scenario: String, game: Simulation, diagnostics: Diagnostics) -> String:
	var state := game.state
	match scenario:
		"second_porter":
			if state.porter_count == 1 and game.elapsed_seconds() == 0:
				return "HIRE_PORTER" if _affordable(game, "HIRE_PORTER") else ""
		"even":
			var candidates := ALL.filter(func(code: String) -> bool:
				return game.economy.next_price(state, code) >= 0)
			candidates.sort_custom(func(a: String, b: String) -> bool:
				var a_level := game.economy.purchase_level(state, a)
				var b_level := game.economy.purchase_level(state, b)
				return ALL.find(a) < ALL.find(b) if a_level == b_level else a_level < b_level)
			if not candidates.is_empty() and _affordable(game, candidates[0]):
				return candidates[0]
		"transport":
			return _cheapest(game, TRANSPORT)
		"mining":
			return _cheapest(game, BY_STAGE.miner)
		"bottleneck":
			var scores := diagnostics.limits()
			var stage := ""
			var score := 0
			for key in scores:
				if scores[key] > score:
					stage = key
					score = scores[key]
			if not stage.is_empty():
				return _cheapest(game, BY_STAGE[stage])
	return ""


func _affordable(game: Simulation, code: String) -> bool:
	var price := game.economy.next_price(game.state, code)
	return price >= 0 and price <= game.state.currency


func _cheapest(game: Simulation, codes: Array) -> String:
	var result := ""
	var best := game.state.currency + 1
	for code: String in codes:
		var price := game.economy.next_price(game.state, code)
		if price >= 0 and price < best:
			best = price
			result = code
	return result


func _write_trace(file: FileAccess, game: Simulation, totals: PackedInt32Array, diagnostics: Diagnostics) -> void:
	var state := game.state
	var levels := {}
	for code in ALL:
		levels[code] = game.economy.purchase_level(state, code)
	var on_trip := 0
	for index in range(state.porter_count):
		if state.worker(Owner.FIRST_PORTER + index).fsm_state != &"idle":
			on_trip += 1
	var layer := state.geometry.quarry_depth(int(totals[0]))
	_csv(file, [game.elapsed_seconds(), totals[0], totals[1], totals[2], totals[4], state.currency,
		state.porter_count, JSON.stringify(levels), state.stock_count(Owner.QUARRY),
		state.stock_count(Owner.RAW), state.stock_count(Owner.FINISHED), state.stock_count(Owner.PLATFORM),
		layer, state.current_row, on_trip, JSON.stringify(diagnostics.rates()),
		JSON.stringify(diagnostics.blocked_seconds()), JSON.stringify(diagnostics.limits())])


func _csv(file: FileAccess, values: Array) -> void:
	file.store_csv_line(PackedStringArray(values.map(func(value: Variant) -> String: return str(value))))


func _fail(message: String) -> bool:
	printerr(message)
	return false
