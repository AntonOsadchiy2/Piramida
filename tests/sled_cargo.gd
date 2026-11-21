extends RefCounted

const State = preload("res://scripts/domain/game_state.gd")
const Presenter = preload("res://scripts/presentation/world_presenter.gd")
var seen := {}
var resumed := {}
var captured := {}
var stable_transfer := {}


func check_scaffold_clearance(wallpaper) -> void:
	var world = wallpaper.world
	var sled: Sprite2D = world._views[State.Owner.BUILDER].sled
	var route := PackedVector2Array([
		Vector2(8.64, 0.0), Vector2(8.865, 1.12), Vector2(9.36, 1.12),
	])
	var worker := Vector2(900.0, -112.0)
	world._fit_sled_to_route(sled, route, 1, worker, 1.0, 68.0)
	var half_width := sled.texture.get_width() * sled.scale.x * 0.5
	var bottom := (sled.texture.get_height() * 0.5 + sled.offset.y) * sled.scale.y
	for index in range(17):
		var local := Vector2(lerpf(-half_width, half_width, float(index) / 16.0), bottom)
		var edge := local.rotated(sled.rotation)
		var surface_y: float = world._tow_surface_y(route, 1, 1.0, worker.x + sled.position.x + edge.x)
		assert(worker.y + sled.position.y + edge.y <= surface_y + 0.01,
			"The sled runner must stay above the scaffold and ground")


func check_mixed_layout(wallpaper) -> void:
	# A full batch is uncommon in the short six-block production run. Exercise
	# it separately without changing the live simulation or its reservations.
	var state := State.new(wallpaper._balance)
	var id := State.Owner.FIRST_PORTER
	for resource_id in range(6):
		state._move(resource_id, State.Owner.UNMINED, id)
	var view: Dictionary = wallpaper.world._views[id]
	for brick in [false, true]:
		wallpaper.world._sync_sled_cargo(state, id, view, brick)
		var previous_right := -INF
		assert(view.sled_factor > 2.0, "The whole row must determine sled width")
		for index in range(6):
			var item: Sprite2D = view.items[index]
			var rect: Rect2 = item.texture.get_meta("cargo_bounds")
			rect.position -= item.texture.get_size() * 0.5
			var left: Vector2 = (item.position + rect.position * item.scale) * view.sled.scale
			var right: Vector2 = (item.position + rect.end * item.scale) * view.sled.scale
			assert(left.x >= previous_right + Presenter.SLED_CARGO_GAP - 0.01)
			assert(is_equal_approx(right.y, Presenter.SLED_DECK_Y * view.sled_factor))
			previous_right = right.x
	seen.mixed = true
	wallpaper.world.sync_state(wallpaper.simulation.state, true)


func check_frame(wallpaper) -> void:
	var world = wallpaper.world
	var state: State = wallpaper.simulation.state
	world.render_frame(1.0, wallpaper.simulation.elapsed_seconds())
	var resume_id := -1
	for id in state.worker_ids():
		var view: Dictionary = world._views[id]
		if not view.has("sled"):
			continue
		var ids := state.stock(id)
		if State.role_for_id(id) == State.Worker.Role.BUILDER and not ids.is_empty() \
				and state.worker(id).remaining_distance > 0.0:
			assert(not view.tow_route.is_empty(), "Loaded builder sled needs its walking route")
		if view.has("transfer_item"):
			ids.append_array(state.pickup_targets(id))
		var largest := 1
		var previous_right := -INF
		var bottom := INF
		for index in range(ids.size()):
			var size := state.geometry.block_size_for_resource(ids[index])
			largest = maxi(largest, size)
			seen[str(size)] = true
			var item: Sprite2D = view.items[index]
			var expected := Vector2.ONE * size if item.texture == world._art.brick else state.geometry.brick_size() * (100.0 * size * Presenter.LIMESTONE_SCALE) / item.texture.get_size()
			assert((item.scale * view.sled.scale).is_equal_approx(expected), "Cargo must not be scaled twice")
		var k: float = view.sled_factor
		assert(k >= largest * Presenter.LARGE_CARGO_SLED_FACTOR)
		if largest == 1:
			assert(k == 1.0 and world._sled_distance(view) == 94.0)
		else:
			if ids.size() == 1:
				assert(is_equal_approx(k, maxf(1.0, largest * Presenter.LARGE_CARGO_SLED_FACTOR)))
			else:
				seen.mixed = true
			for index in range(ids.size()):
				var item: Sprite2D = view.items[index]
				var rect: Rect2 = item.texture.get_meta("cargo_bounds")
				rect.position -= item.texture.get_size() * 0.5
				var left: Vector2 = (item.position + rect.position * item.scale) * view.sled.scale
				var right: Vector2 = (item.position + rect.end * item.scale) * view.sled.scale
				assert(left.x >= previous_right + Presenter.SLED_CARGO_GAP - 0.01)
				assert(is_inf(bottom) or is_equal_approx(bottom, right.y), "Cargo bottoms must share the deck")
				assert(is_equal_approx(right.y, Presenter.SLED_DECK_Y * k))
				previous_right = right.x
				bottom = right.y
		if view.tether.visible:
			var hitch := Presenter.WALLPAPER_SLED_HITCH * k
			hitch.x *= -1.0 if view.sled.flip_h else 1.0
			assert(view.tether.get_point_position(1).is_equal_approx(view.sled.position + hitch.rotated(view.sled.rotation)))
			if largest > 1:
				seen["left" if view.sled.flip_h else "right"] = true
				if absf(view.sled.rotation) > 0.01:
					seen.slope = true
		if view.get("transferring", false):
			var key := "%s/%s/%s/%s" % [id, state.transfer_source(id), view.transfer_id, view.loading]
			var layout := [view.sled.scale, view.transfer_sled, view.transfer_sled_scale]
			var manifest := state.stock(id)
			manifest.append_array(state.pickup_targets(id))
			if stable_transfer.has(key) and stable_transfer[key].manifest == manifest:
				assert(stable_transfer[key].layout == layout,
					"Transfer layout must remain fixed for the same cargo manifest")
			stable_transfer[key] = {"manifest": manifest, "layout": layout}
			var phase := "%s-%s" % [largest, "load" if view.loading else "unload"]
			if largest > 1 and view.transfer_after > 0.0 and view.transfer_after < 1.0 and not resumed.has(phase):
				resumed[phase] = true
				resume_id = id
		if largest > 1 and view.sled.visible:
			var label := "%s-%s" % [largest, "transfer" if view.get("transferring", false) else "haul"]
			if not captured.has(label) and "--sled-captures" in OS.get_cmdline_user_args():
				captured[label] = true
				var camera: Camera2D = world.get_node("Camera2D")
				camera.position = view.root.position + view.sled.position * 0.5 + Vector2(0, -90)
				camera.zoom = Vector2.ONE * 1.5
				camera.force_update_scroll()
				await RenderingServer.frame_post_draw
				var path := OS.get_environment("TEMP").path_join("piramida63-%s.png" % label)
				assert(wallpaper.get_viewport().get_texture().get_image().save_png(path) == OK)
				print("Captured ", path)
	if resume_id >= 0:
		var view: Dictionary = world._views[resume_id]
		var before := [view.sled.scale, view.sled.position, view.transfer_item.global_position, view.transfer_item.scale]
		var model: Dictionary = wallpaper.simulation.to_dict()
		assert(wallpaper._save_progress())
		wallpaper._resume_cycle()
		wallpaper.world.render_frame(1.0, wallpaper.simulation.elapsed_seconds())
		view = wallpaper.world._views[resume_id]
		var after := [view.sled.scale, view.sled.position, view.transfer_item.global_position, view.transfer_item.scale]
		for index in range(before.size()):
			assert(before[index].is_equal_approx(after[index]), "Large cargo jumps after resume")
		assert(wallpaper.simulation.to_dict() == model)


func finish() -> void:
	for key in ["1", "2", "4", "mixed", "left", "right", "slope"]:
		assert(seen.has(key), "Missing sled coverage: " + key)
	for key in ["2-load", "2-unload", "4-load", "4-unload"]:
		assert(resumed.has(key), "Missing resume coverage: " + key)
	print("PASS: sled sizes 1/2/4, mixed cargo, deck bounds, both directions, slopes, stable transfer and real save/resume")
