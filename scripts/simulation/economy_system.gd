extends RefCounted
class_name EconomySystem

const State = preload("res://scripts/domain/game_state.gd")
const Owner = State.Owner
const SPEED_WORKERS := {
	"MINER_SPEED": Owner.MINER,
	"DRESSER_SPEED": Owner.DRESSER,
	"BUILDER_SPEED": Owner.BUILDER,
}

var _coins_per_brick: int
var _coins_per_row: int
var _upgrades: Dictionary
var _enabled: bool


func _init(balance: Dictionary, enabled: bool = true) -> void:
	_enabled = enabled
	_coins_per_brick = int(balance.economy.coinsPerBrick)
	_coins_per_row = int(balance.economy.coinsPerRow)
	_upgrades = balance.upgrades.duplicate(true)


func credit_placement(state: State, row_complete: bool) -> void:
	if _enabled:
		state.currency += _coins_per_brick + (_coins_per_row if row_complete else 0)


func purchase_level(state: State, code: String) -> int:
	match code:
		"PORTER_CAPACITY":
			return state.porter_capacity
		"HIRE_PORTER":
			return state.porter_count
	return state.upgrade_levels.get(code, 1)


# A negative price means the purchase is unavailable.
func next_price(state: State, code: String) -> int:
	if not _enabled or state.finished:
		return -1
	var level := purchase_level(state, code)
	match code:
		"PORTER_CAPACITY":
			var costs: Array = _upgrades.capacityCosts
			if level <= costs.size() and level < State.MAX_PORTER_CAPACITY:
				return int(costs[level - 1])
		"HIRE_PORTER":
			if state.can_add_porter():
				return _round_to_five(float(_upgrades.hireBaseCost) *
					pow(float(_upgrades.hirePriceMultiplier), level - 1))
		_:
			if (code == "PORTER_SPEED" or SPEED_WORKERS.has(code)) \
					and _upgrades.speed.has(code) and level < int(_upgrades.maxSpeedLevel):
				return _round_to_five(float(_upgrades.speed[code].baseCost) *
					pow(float(_upgrades.speedPriceMultiplier), level - 1))
	return -1


# The quoted level makes a repeated or stale command harmless.
func try_purchase(state: State, code: String, expected_level: int) -> bool:
	var price := next_price(state, code)
	if price < 0 or state.currency < price or expected_level != purchase_level(state, code):
		return false

	state.currency -= price
	match code:
		"PORTER_CAPACITY":
			state.porter_capacity += 1
		"HIRE_PORTER":
			state.add_porter()
		_:
			state.upgrade_levels[code] = expected_level + 1
			var multiplier := pow(float(_upgrades.speed[code].multiplier), expected_level)
			if code == "PORTER_SPEED":
				for index in range(state.porter_count):
					state.worker(Owner.FIRST_PORTER + index).speed_multiplier = multiplier
			else:
				state.worker(SPEED_WORKERS[code]).speed_multiplier = multiplier
	return true


func _round_to_five(value: float) -> int:
	return floori(value / 5.0 + 0.5) * 5
func speed_effect(code: String) -> float:
	return float(_upgrades.speed[code].multiplier)
