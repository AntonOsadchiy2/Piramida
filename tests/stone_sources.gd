extends SceneTree

const State = preload("res://scripts/domain/game_state.gd")
const ConstructionProduction = preload("res://scripts/simulation/construction_production.gd")
const QuarryProduction = preload("res://scripts/simulation/quarry_production.gd")
const Wallpaper = preload("res://scripts/application/wallpaper.gd")

var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)


func _run() -> void:
	var balance: Dictionary = Wallpaper.wallpaper_balance(
		JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json")))
	var quarry_only := State.new(balance)
	quarry_only._move(0, State.Owner.UNMINED, State.Owner.QUARRY_STOCK)
	ConstructionProduction.new(quarry_only, balance).assign_tasks()
	_check(quarry_only.stock_count(State.Owner.QUARRY_STOCK) == 0
		and quarry_only.stock(State.Owner.DRESSER) == [0]
		and quarry_only.worker(State.Owner.DRESSER).fsm_state == &"process_brick",
		"Dresser must take one stone from quarry stock and begin processing")
	_check(not quarry_only.pick_up(State.Owner.DRESSER, 0),
		"Dresser must not take the same stone twice")
	_check(quarry_only.validate().is_empty(), "Quarry stock pickup must preserve inventory")

	var both := State.new(balance)
	both._move(0, State.Owner.UNMINED, State.Owner.RAW)
	both._move(1, State.Owner.UNMINED, State.Owner.QUARRY_STOCK)
	ConstructionProduction.new(both, balance).assign_tasks()
	_check(both.stock_count(State.Owner.RAW) == 0
		and both.stock(State.Owner.DRESSER) == [0]
		and both.stock(State.Owner.QUARRY_STOCK) == [1],
		"Dresser must consume only its selected source")
	_check(both.validate().is_empty(), "Two source pickup must preserve inventory")

	var porter_state := State.new(balance)
	porter_state._move(0, State.Owner.UNMINED, State.Owner.WORKSHOP_OUTPUT)
	porter_state._move(1, State.Owner.UNMINED, State.Owner.QUARRY_STOCK)
	QuarryProduction.new(porter_state, balance.workers).assign_tasks()
	var porter := State.Owner.FIRST_PORTER
	_check(porter_state.transfer_source(porter) == State.Owner.QUARRY_STOCK
		and porter_state._tasks[porter].destination == State.Owner.RAW
		and porter_state.stock(State.Owner.WORKSHOP_OUTPUT) == [0],
		"Porter must deliver raw stone only to dresser stock")
	_check(porter_state.pick_up(porter, 1) and porter_state.deliver(porter, 1)
		and porter_state.stock(State.Owner.RAW) == [1]
		and porter_state.stock(State.Owner.WORKSHOP_OUTPUT) == [0],
		"Porter delivery must place exactly one stone in dresser stock")
	_check(porter_state.validate().is_empty(), "Porter reservation must preserve inventory")

	if failures == 0:
		print("PASS: stone sources and porter destination")
	quit(int(failures > 0))
