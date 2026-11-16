extends RefCounted

const Simulation = preload("res://scripts/simulation/simulation_runner.gd")

signal save_requested

var enabled := true
var _simulation: Simulation


func _init(simulation: Simulation) -> void:
	_simulation = simulation


func purchase(code: String, expected_level: int) -> bool:
	if not enabled or not _simulation.economy.try_purchase(_simulation.state, code, expected_level):
		return false
	save_requested.emit()
	return true

func quote(code: String) -> Dictionary:
	var state := _simulation.state
	var economy := _simulation.economy
	var price := economy.next_price(state, code)
	return {
		"level": economy.purchase_level(state, code),
		"price": price,
		"available": enabled and price >= 0 and state.currency >= price,
	}
