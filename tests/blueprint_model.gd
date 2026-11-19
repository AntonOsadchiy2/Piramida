extends SceneTree

const Blueprint = preload("res://scripts/domain/blueprint.gd")
const Simulation = preload("res://scripts/simulation/simulation_runner.gd")
const Wallpaper = preload("res://scripts/application/wallpaper.gd")
const PanelSettings = preload("res://scripts/application/panel_settings.gd")
const SaveService = preload("res://scripts/application/save_service.gd")
const Weather = preload("res://scripts/application/wallpaper_weather.gd")

func _initialize() -> void:
	var valid := {"version": 1, "blocks": [
		{"x": 4, "y": 1, "size": 1, "type": "stone"},
		{"x": 0, "y": 0, "size": 1, "type": "stone"},
		{"x": 0, "y": 1, "size": 1, "type": "stone"},
		{"x": 4, "y": 0, "size": 1, "type": "stone"},
		{"x": 0, "y": 2, "size": 1, "type": "stone"},
		{"x": 4, "y": 2, "size": 1, "type": "stone"},
		{"x": 0, "y": 3, "size": 1, "type": "stone"},
		{"x": 4, "y": 3, "size": 1, "type": "stone"},
	]}
	for y in range(4, 30):
		for x in [0, 4]:
			valid.blocks.append({"x": x, "y": y, "type": "stone", "size": 1})
	var checked := Blueprint.validate(valid)
	assert(not checked.has("error"))
	assert(checked.blocks[0].x == 0 and checked.blocks[1].x == 4)
	assert(Blueprint.validate({"version": 1, "blocks": [valid.blocks[0]]}).has("error"))
	assert(Blueprint.validate({"version": 1, "blocks": [valid.blocks[1], valid.blocks[1]]}).has("error"))
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	var balance := Wallpaper.wallpaper_balance(base)
	balance.world["blueprintBlocks"] = checked.blocks
	balance.world.pyramidRows = 30
	var settings := PanelSettings.validate({
		"version": 1, "minerMove": 4.0, "mineSeconds": 0.5, "porterEmpty": 3.2,
		"porterLoaded": 2.8, "loadSeconds": 0.5, "unloadSeconds": 0.7,
		"dressSeconds": 1.0, "dresserMove": 3.2, "liftBase": 1.5,
		"liftPerRow": 0.15, "rebuildSeconds": 1.0,
		"builderMove": 3.2, "placeSeconds": 1.0, "porterCount": 3,
		"minerCount": 4, "dresserCount": 4, "builderCount": 4,
		"weatherMin": 20, "weatherMax": 30, "weatherTransition": 5,
		"clearWeight": 1, "partlyWeight": 0, "cloudyWeight": 1,
	})
	assert(not settings.is_empty())
	var weather_settings := settings.duplicate()
	weather_settings.clearWeight = 1.0
	weather_settings.partlyWeight = 0.0
	weather_settings.cloudyWeight = 0.0
	var weather := Weather.new()
	weather.configure(weather_settings)
	for step in range(20):
		weather.advance(100.0)
		assert(weather.condition == Weather.Condition.CLEAR and weather.cloud_cover == 0.0)
	PanelSettings.apply(balance, settings)
	var sim := Simulation.for_wallpaper(balance)
	assert(sim.state.porter_count == 3 and sim.state.worker_ids().size() == 16)
	assert(sim.state.target_count() == 60)
	var scratch := DirAccess.create_temp("blueprint-test-")
	assert(scratch != null)
	var saves := SaveService.new(balance, scratch.get_current_dir().path_join("save.json"))
	assert(saves.save_game(sim) == OK)
	assert(saves.load_game().status == SaveService.Status.OK)
	var restored := false
	var reference: Simulation
	var worked := {"mine": {}, "process_brick": {}, "place_brick": {}}
	for i in range(100000):
		var events: Array = sim.step_simulation()
		for event in events:
			if worked.has(String(event.state)):
				worked[String(event.state)][event.worker_id] = true
		if reference != null:
			reference.step_simulation()
			assert(JSON.stringify(sim.to_dict(), "", true) == JSON.stringify(reference.to_dict(), "", true))
		if i % 25 == 0:
			assert(sim.state.validate().is_empty())
			if Simulation.from_dict(balance, sim.to_dict()) == null:
				print("FAILED snapshot tick ", i, " ", JSON.stringify(sim.timing_snapshot()))
				quit(1)
				return
		if not restored and sim.state.placed_count() == 2:
			assert(saves.save_game(sim) == OK)
			var loaded := saves.load_game()
			assert(loaded.status == SaveService.Status.OK)
			reference = sim
			sim = loaded.simulation
			restored = true
		if sim.state.finished:
			break
	assert(restored and sim.state.finished and sim.state.placed_count() == 60)
	assert(sim.state.validate().is_empty())
	for action in worked:
		assert(worked[action].size() == 4, "Each role must have multiple active workers: " + action)
	print("PASS: supported separated blueprint, multiple workers, deterministic resume and completion")
	quit()
