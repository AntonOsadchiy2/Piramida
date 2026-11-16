extends SceneTree

const State = preload("res://scripts/domain/game_state.gd")
const Saves = preload("res://scripts/application/save_service.gd")
const Lifecycle = preload("res://scripts/application/lifecycle_controller.gd")
const Scene = preload("res://scenes/main.tscn")
const Owner = State.Owner

var samples: Dictionary = {}


func _initialize() -> void:
	run.call_deferred()


func record(label: String, started: int) -> void:
	if not samples.has(label):
		samples[label] = []
	samples[label].append(Time.get_ticks_usec() - started)


func report() -> void:
	for label in samples:
		var times: Array = samples[label]
		times.sort()
		print("%s n=%d p50=%d p95=%d max=%d us" % [label, times.size(),
			times[times.size() / 2], times[ceili(times.size() * 0.95) - 1], times[-1]])


func run() -> void:
	var balance: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	balance.workers.porter.count = 8
	balance.workers.porter.capacity = 4
	balance.workers.miner.mineSeconds = 0.1
	balance.workers.miner.moveSpeed = 100.0
	balance.workers.porter.emptySpeed = 100.0
	balance.workers.porter.loadedSpeed = 100.0
	balance.workers.porter.loadSeconds = 0.1
	balance.workers.porter.unloadSeconds = 0.1

	var path := OS.get_environment("TEMP").path_join("piramida-profile-%d.json" % OS.get_process_id())
	var saves := Saves.new(balance, path)
	var life := Lifecycle.new(balance, saves, 1000)
	var sim := life.session.simulation
	var state := sim.state
	var scene := Scene.instantiate()
	scene.set_script(null)
	root.add_child(scene)
	var world = scene.get_node("World")
	var hud = scene.get_node("HUD/Control")
	var camera = world.get_node("Camera2D")
	var started := Time.get_ticks_usec()
	world.setup(state, balance)
	hud.setup(life, balance)
	record("setup", started)
	await process_frame

	var peaks := [0, 0, 0, 0]
	var first_full := false
	for tick in range(150000):
		sim.step_simulation()
		var counts := [state.stock_count(Owner.QUARRY), state.stock_count(Owner.RAW),
			state.stock_count(Owner.FINISHED), state.stock_count(Owner.PLATFORM)]
		for i in range(counts.size()):
			peaks[i] = maxi(peaks[i], counts[i])
		started = Time.get_ticks_usec()
		world.capture_tick(state)
		record("capture", started)
		started = Time.get_ticks_usec()
		hud.tick()
		record("hud_tick", started)
		if not first_full and counts[1] == int(balance.storages.raw):
			first_full = true
			await sample_frames(world, camera, sim.elapsed_seconds(), "full_raw")
		if state.placed_count() == 850 and not samples.has("late_present"):
			await sample_frames(world, camera, sim.elapsed_seconds(), "late")
		if state.finished:
			break
	print("Placed=", state.placed_count(), " workers=", state.worker_ids().size(), " stock peaks=", peaks)
	await sample_frames(world, camera, sim.elapsed_seconds(), "victory")
	var success := state.finished and state.validate().is_empty()
	for i in range(20):
		started = Time.get_ticks_usec()
		var error := saves.save_game(sim)
		record("save", started)
		started = Time.get_ticks_usec()
		var loaded := saves.load_game()
		record("load", started)
		success = success and error == OK and loaded.status == Saves.Status.OK
		if not success:
			break
		success = loaded.simulation.to_dict() == sim.to_dict()

	var offline_path := path + ".offline"
	var offline := Lifecycle.new(balance, Saves.new(balance, offline_path), 1000)
	offline.enter_background(1000)
	offline.enter_foreground(15400)
	started = Time.get_ticks_usec()
	while offline.mode == Lifecycle.Mode.RESTORING:
		var batch_start := Time.get_ticks_usec()
		offline.advance_frame(0.0)
		record("offline_batch", batch_start)
		if samples.offline_batch.size() >= 5000:
			break
	record("offline_total", started)
	success = success and offline.session.simulation.to_dict() == sim.to_dict()

	report()
	for file in [path, offline_path]:
		for suffix in ["", ".tmp", ".bak"]:
			if FileAccess.file_exists(file + suffix):
				DirAccess.remove_absolute(file + suffix)
	quit(0 if success else 1)


func sample_frames(world: Node, camera: Camera2D, game_seconds: float, label: String) -> void:
	camera.show_construction()
	var center := root.get_visible_rect().size * 0.5
	for frame in range(120):
		var started := Time.get_ticks_usec()
		camera._transform_view(center, center + Vector2(4 if frame % 2 == 0 else -4, 0),
			1.02 if frame < 60 else 1.0 / 1.02)
		record("camera", started)
		started = Time.get_ticks_usec()
		world.render_frame(float(frame % 6) / 5.0, game_seconds)
		record(label + "_present", started)
		await process_frame
