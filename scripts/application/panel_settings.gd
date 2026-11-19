extends RefCounted
## The panel writes complete settings. Reject the whole file on invalid input.

static func validate(value: Variant) -> Dictionary:
	if not value is Dictionary or value.get("version") != 1:
		return {}
	var fields := {
		"sizePenalty": [1.0, 10.0],
		"minerMove": [0.1, 20.0], "mineSeconds": [0.1, 120.0],
		"porterEmpty": [0.1, 20.0], "porterLoaded": [0.1, 20.0],
		"dressSeconds": [0.1, 120.0], "dresserMove": [0.1, 20.0], "builderMove": [0.1, 20.0],
		"loadSeconds": [0.1, 120.0], "unloadSeconds": [0.1, 120.0],
		"liftBase": [0.1, 120.0], "liftPerRow": [0.0, 30.0], "rebuildSeconds": [0.1, 120.0],
		"placeSeconds": [0.1, 120.0], "porterCount": [1.0, 4.0],
		"minerCount": [1.0, 4.0], "dresserCount": [1.0, 4.0], "builderCount": [1.0, 4.0],
		"weatherMin": [1.0, 3600.0], "weatherMax": [1.0, 3600.0],
		"weatherTransition": [0.1, 3600.0],
		"clearWeight": [0.0, 100.0], "partlyWeight": [0.0, 100.0], "cloudyWeight": [0.0, 100.0],
	}
	var result := {"version": 1}
	for key in fields:
		var n: Variant
		if value.has(key):
			n = value[key]
		elif key == "sizePenalty":
			n = 1.5
		if not (n is int or n is float) or not is_finite(float(n)) \
				or float(n) < fields[key][0] or float(n) > fields[key][1]:
			return {}
		result[key] = float(n)
	for key in ["porterCount", "minerCount", "dresserCount", "builderCount"]:
		if result[key] != floor(result[key]):
			return {}
		result[key] = int(result[key])
	if result.weatherMin > result.weatherMax \
			or result.clearWeight + result.partlyWeight + result.cloudyWeight <= 0.0:
		return {}
	return result


static func apply(balance: Dictionary, settings: Dictionary) -> void:
	balance.workers.miner.count = settings.minerCount
	balance.workers.dresser.count = settings.dresserCount
	balance.workers.builder.count = settings.builderCount
	balance.workers.miner.moveSpeed = settings.minerMove
	balance.workers.miner.mineSeconds = settings.mineSeconds
	balance.workers.porter.emptySpeed = settings.porterEmpty
	balance.workers.porter.loadedSpeed = settings.porterLoaded
	balance.workers.porter.loadSeconds = settings.loadSeconds
	balance.workers.porter.unloadSeconds = settings.unloadSeconds
	balance.workers.porter.count = settings.porterCount
	balance.workers.dresser.processSeconds = settings.dressSeconds
	balance.workers.dresser["moveSpeed"] = settings.dresserMove
	balance.lift.baseSeconds = settings.liftBase
	balance.lift.secondsPerRow = settings.liftPerRow
	balance.lift.rebuildSeconds = settings.rebuildSeconds
	balance.workers.builder.moveSpeed = settings.builderMove
	balance.workers.builder.placeSeconds = settings.placeSeconds
	balance.world["sizePenalty"] = float(settings.get("sizePenalty", 1.5))
