extends RefCounted

const Simulation = preload("res://scripts/simulation/simulation_runner.gd")
const Commands = preload("res://scripts/application/purchase_commands.gd")
const SaveService = preload("res://scripts/application/save_service.gd")

var simulation: Simulation
var purchases: Commands
var lifecycle: Dictionary = {}
var last_save_error: Error = OK
var _service: SaveService
var _pending := false
var _next_save_at: float
var _interval: float


func _init(game: Simulation, service: SaveService, balance: Dictionary) -> void:
	simulation = game
	_service = service
	_interval = float(balance.simulation.autosaveSeconds)
	_next_save_at = game.elapsed_seconds() + _interval
	purchases = Commands.new(game)
	purchases.save_requested.connect(request_save)


func step_simulation() -> Array[Dictionary]:
	var rows := simulation.state.completed_rows
	var events := simulation.step_simulation()
	if simulation.state.completed_rows != rows or simulation.elapsed_seconds() >= _next_save_at:
		request_save()
	flush_save()
	return events


func request_save() -> void:
	_pending = true


# A caller can also flush at the current boundary, for example before closing.
func flush_save() -> Error:
	if _pending:
		last_save_error = _service.save_game(simulation, lifecycle)
		if last_save_error == OK:
			_pending = false
			_next_save_at = simulation.elapsed_seconds() + _interval
	return last_save_error
