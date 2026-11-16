extends Node2D

signal wallpaper_sky_area_changed

const State = preload("res://scripts/domain/game_state.gd")
const Owner = State.Owner
const Geometry = State.Geometry
const PIXELS_PER_UNIT := 100.0
# The visible stone is about 39 × 31 px after accounting for PNG padding.
const RAW_STONE_SCALE := Vector2(0.94, 0.75)
const ASSETS := "res://assets/sprites/"
const PLACEHOLDERS := "res://assets/placeholders/"
const SAND_SCALE := 0.5
const WALLPAPER_SAND := preload("res://assets/wallpaper/sand.png")
const WALLPAPER_ART := [
	"lift_cradle", "lift_pulley", "platform",
	"beam", "post", "dust",
]
const WORKER_ART := {
	Owner.MINER: "miner", Owner.DRESSER: "dresser", Owner.BUILDER: "builder"
}
const WorkerWalk = preload("res://scripts/presentation/worker_walk.gd")
const SiteOverseer = preload("res://scripts/presentation/site_overseer.gd")
const ACTIONS := [&"mine", &"process_brick", &"place_brick", &"load", &"unload", &"unload_at_lift", &"operate_lift"]
const WORKER_FRAME_SCALE := 1.25
const CRANK_STANCE_SHIFT := 26.0
const CRANK_STANCE_APPROACH := 90.0
const MINE_STRIKE_FEET := Vector2(29.66, 83.90)
# The lower tip of the pick in mine-1.png, in unflipped texture coordinates.
const MINE_PICK_TIP := Vector2(73.5, 78.5)
const MINER_STANCE := (MINE_STRIKE_FEET - MINE_PICK_TIP) * Vector2(-1, 1) * WORKER_FRAME_SCALE
const BUILDER_PLACE := preload("res://assets/sprites/builder-place.png")
const BUILDER_PLACE_FEET := Vector2(94.15, 86.0)
# The midpoint between the open hands in builder-place.png.
const BUILDER_PLACE_GRIP := (Vector2(128.5, 63.5) - BUILDER_PLACE_FEET) * WORKER_FRAME_SCALE
const BUILDER_PLACEMENT_APPROACH := 88.0
const BUILDER_LIFT_APPROACH := 110.0
const PORTER_SLED_DISTANCE := 94.0
const WALLPAPER_SLED_HITCH := Vector2(50.0, -11.0)
const PORTER_SLED_COLUMNS := 3
const PORTER_SLED_COLUMN_SPACING := 42.0
const PORTER_SLED_ROW_RISE := 52.0
const DRESSER_REST := preload("res://assets/sprites/dress-idle.png")
const DRESSER_REST_SHADER := preload("res://scripts/presentation/dresser_rest.gdshader")
const DRESSER_REST_FEET := Vector2(31.17, 72.0)
const SIMPLE_FRAMES := {
	"mine": [MINE_STRIKE_FEET, Vector2(33.97, 111.09)],
	"dress": [Vector2(30.93, 72.58), Vector2(30.26, 82.28)],
}
const SKY_ASSETS := "res://assets/wallpaper/sky/"
const SKY_SHADER := preload("res://scripts/presentation/sky_palette.gdshader")
const SKY_EDGE_FADE := 0.015
const BODY_HORIZON_FADE := 0.01 # 0.9 degrees in the normalized projection.
const MOON_DISC_CENTER := Vector2(0.493, 0.487)
const MOON_DISC_RADIUS := 0.438
# Lower magnitudes are brighter. Regions trim padding around the original centers.
const STAR_STYLES := [
	{"max_magnitude": 1.3, "file": "star_04_bright_spark_128.png",
		"region": Rect2(30, 28, 68, 72), "height_px": 10.0},
	{"max_magnitude": 2.1, "file": "star_02_warm_cross_128.png",
		"region": Rect2(46, 46, 36, 36), "height_px": 7.5},
	{"max_magnitude": 2.8, "file": "star_03_cool_diamond_128.png",
		"region": Rect2(48, 46, 32, 36), "height_px": 6.0},
	{"max_magnitude": 3.4, "file": "star_05_violet_glint_128.png",
		"region": Rect2(32, 32, 64, 64), "height_px": 4.5},
	{"max_magnitude": INF, "file": "star_01_tiny_dot_128.png",
		"region": Rect2(60, 58, 8, 12), "height_px": 2.0},
]

@onready var pyramid: TileMapLayer = $PyramidTiles
@onready var workers: Node2D = $Workers
@onready var cargo: Node2D = $Cargo

var _art: Dictionary[String, Texture2D] = {}
var _worker_frames: Dictionary = {}
var _sky_area: Rect2
var _sky_background: Sprite2D
var _sky_material: ShaderMaterial
var _sun: Sprite2D
var _moon: Sprite2D
var _stars: Node2D
var _star_textures: Array[Texture2D] = []
var _quarry_cut: Polygon2D
var _quarry_rim: Line2D
var _foreground: Polygon2D
var _foreground_rect: Rect2
var _star_points := PackedVector3Array()
var _views: Dictionary[int, Dictionary] = {}
var overseer: SiteOverseer
var _piles: Dictionary[int, Array] = {}
var _quarry_stones: Array[Sprite2D] = []
var _brick_cells: Array[Vector2i] = []
var _placing_brick: Sprite2D
var _placement_before := 0.0
var _placement_after := 0.0
var _builder_brick_target := Vector2.ZERO
var _builder_lift_stance := 0.0
var _platform: Sprite2D
var _deck: Sprite2D
var _pyramid_ramp: Polygon2D
var _mast: Sprite2D
var _pulley: Sprite2D
var _crank: Node2D
var _crank_grip: Node2D
var _crank_seconds_left := 0.0
var _rope: Line2D
var _upper_cable: Line2D
var _cable_support: Sprite2D
var _effects: Dictionary[StringName, Sprite2D]
var _effect_tweens: Dictionary[StringName, Tween]
var _platform_before: Vector2
var _platform_after: Vector2
var _platform_pile_anchor := Vector2.INF
var _lift_base: Vector2
var _brick_height: float
var _step_seconds: float
var _geometry: Geometry
var _world: Dictionary
var _mined := 0
var _placed := 0
var _row := 0
var _deck_end := 0.0
var _rebuilding := false
var _finished := false


static func screen_point(point: Vector2) -> Vector2:
	return Vector2(point.x, -point.y) * PIXELS_PER_UNIT


func setup(state: State, balance: Dictionary, configure_patrol: Callable = Callable(),
		transfer_facing: Dictionary = {}) -> void:
	_geometry = state.geometry
	_world = balance.world
	_step_seconds = float(balance.simulation.fixedStepSeconds)
	for action in SIMPLE_FRAMES:
		var folder := ASSETS if action == "mine" else "res://assets/wallpaper/workers/"
		var frames: Array[Texture2D] = []
		for index in range(SIMPLE_FRAMES[action].size()):
			var file := "%s-%d" % [action, index + 1]
			frames.append(load(folder + file + ".png"))
		_worker_frames[action] = frames
	for name in ["brick", "stone", "workshop_canopy",
			"lift_cradle", "lift_pulley", "platform",
			"beam", "post", "sled", "miner", "porter", "dresser", "builder", "dust"]:
		if name == "sled":
			_art[name] = load("res://assets/wallpaper/sled.png")
		elif name in WALLPAPER_ART:
			_art[name] = load(PLACEHOLDERS + name + ".svg")
		else:
			_art[name] = load(ASSETS + name + ".png")

	var layers := _geometry.quarry_layers()
	var radius := float(layers) - 0.5
	var pit_left := screen_point(_geometry.quarry_grid_point(Vector2(-radius, 0))).x
	var pit_right := screen_point(_geometry.quarry_grid_point(Vector2(radius, 0))).x
	var pit_bottom := screen_point(_geometry.quarry_grid_point(Vector2(0, layers))).y
	var brick := _geometry.brick_size() * PIXELS_PER_UNIT
	_brick_height = brick.y
	var left := screen_point(_geometry.brick_origin(0, 0)).x
	var right := left + _geometry.row_size(0) * brick.x
	_make_brick_tiles(Vector2i(brick), Vector2(left, -brick.y))
	for row in range(int(_world.pyramidRows)):
		for column in range(_geometry.row_size(row)):
			var point := screen_point(_geometry.brick_origin(row, column))
			var tile := Vector2i(roundi((point.x - left) / brick.x), -row)
			_brick_cells.append(tile)
			pyramid.set_cell(tile, 0, Vector2i.ZERO, 1)
	_placing_brick = _sprite("brick", self)
	_placing_brick.z_index = pyramid.z_index
	_placing_brick.hide()

	# The original framing and background belong to the upper scene.
	var original_left := -1080.0
	var original_bottom := 840.0
	var landscape_left := original_left - 1800.0
	var landscape_width := right - landscape_left + 1800.0
	_create_sky()
	var terrace_y := screen_point(_geometry.quarry_mouth()).y
	_create_terraces(Rect2(landscape_left, terrace_y, landscape_width, pit_bottom - terrace_y + 1200))
	for effect: StringName in [&"dust"]:
		if not _art.has(effect):
			continue
		var sprite := _sprite(effect, self)
		sprite.z_index = 6
		sprite.hide()
		_effects[effect] = sprite
	# A simultaneous quarry strike must not move the placement dust away from the brick.
	var placement_dust := _sprite("dust", self)
	placement_dust.z_index = 6
	placement_dust.hide()
	_effects[&"placement_dust"] = placement_dust

	var canopy := _prop("workshop_canopy", _geometry.workshop())
	canopy.scale = Vector2.ONE * 1.5
	# Give the workshop door a little clearance on the right.
	canopy.position.x -= 10.0
	canopy.z_index = -1
	var lift_base: Vector2 = _geometry.platform(0)
	_lift_base = screen_point(lift_base)
	var hub_height := 75.0
	# Keep the inner edge of the textured elbow from folding over the fist.
	var crank_radius := 8.0
	var hub := screen_point(_geometry.lift_operator_position()) + Vector2(51, -hub_height)
	_winch_line(self, [hub + Vector2(-14, hub_height), hub, hub + Vector2(14, hub_height)], 8, Color("#694b35"))
	_crank = Node2D.new()
	_crank.position = hub
	_crank.z_index = 3
	add_child(_crank)
	_winch_line(_crank, [Vector2(-10, 0), Vector2(crank_radius, 0)], 7, Color("#ae7b47"))
	_winch_line(_crank, [Vector2(-1, 0), Vector2(1, 0)], 12, Color("#4c3528"))
	_crank_grip = _winch_line(_crank, [Vector2(-2, 0), Vector2(2, 0)], 8, Color("#66432d"))
	_crank_grip.position.x = crank_radius
	_mast = _sprite("post", self)
	_mast.z_index = 1
	_pulley = _sprite("lift_pulley", self)
	_pulley.scale = Vector2.ONE * 0.65
	_pulley.z_index = 2
	_deck = _sprite("beam", self)
	_deck.z_index = 1
	if _geometry.has_pyramid_ramp():
		_pyramid_ramp = Polygon2D.new()
		_pyramid_ramp.color = Color("#795139")
		_pyramid_ramp.z_index = 1
		add_child(_pyramid_ramp)
	_platform = _sprite("platform", self)
	_platform.offset.y = 16
	_platform.z_index = 2
	_rope = Line2D.new()
	_rope.width = 3
	_rope.default_color = Color("#694b35")
	_rope.z_index = 2
	add_child(_rope)
	_rope.add_point(Vector2.ZERO)
	_rope.add_point(Vector2.ZERO)
	if _geometry.has_upper_delivery():
		_upper_cable = Line2D.new()
		_upper_cable.width = _rope.width
		_upper_cable.default_color = _rope.default_color
		add_child(_upper_cable)
		_upper_cable.add_point(Vector2.ZERO)
		_upper_cable.add_point(Vector2.ZERO)
		_cable_support = _sprite("post", self)

	workers.z_index = 4
	workers.y_sort_enabled = true
	cargo.z_index = 3
	for i in range(int(balance.storages.quarryReadyCapacity)):
		_quarry_stones.append(_sprite("stone", cargo))
	var quarry_stock: Array[Sprite2D] = []
	for i in range(int(balance.storages.quarryStockCapacity)):
		quarry_stock.append(_sprite("stone", cargo))
	_piles[Owner.QUARRY_STOCK] = quarry_stock
	_update_pile(Owner.QUARRY_STOCK, screen_point(_geometry.quarry_stock()), 4, 32, 21)
	for owner in [Owner.RAW, Owner.FINISHED, Owner.PLATFORM, Owner.WORKSHOP_OUTPUT]:
		var key: String = {Owner.RAW: "raw", Owner.FINISHED: "finished", Owner.PLATFORM: "platform",
			Owner.WORKSHOP_OUTPUT: "workshopOutput"}[owner]
		var pool: Array[Sprite2D] = []
		for i in range(int(balance.storages[key])):
			pool.append(_sprite("stone" if owner == Owner.RAW else "brick", cargo))
		_piles[owner] = pool
	_update_pile(Owner.RAW, screen_point(_geometry.raw_storage()) + Vector2(-28, 0), 6, 32, 20)
	# Leave the crank and its stand clear even when the ground stock is full.
	const BASE_PILE_COLUMNS := 6
	var pile_right := hub.x - 22.0
	var pile_left := pile_right - brick.x * BASE_PILE_COLUMNS
	_update_pile(Owner.FINISHED, Vector2((pile_left + pile_right) * 0.5, _lift_base.y),
		BASE_PILE_COLUMNS, brick.x, brick.y)
	_update_pile(Owner.WORKSHOP_OUTPUT, screen_point(_geometry.workshop_pickup()), 3, brick.x, brick.y)

	var top: Vector2 = screen_point(_geometry.brick_origin(int(_world.pyramidRows) - 1, 0))
	var bounds := Rect2(original_left - 125, top.y - 180, right - original_left + 250,
		original_bottom - top.y + 220)
	$Camera2D.setup(bounds,
		Rect2(pit_left - 220, -100, pit_right - pit_left + 440, pit_bottom + 150),
		Rect2(pile_left - 30.0, bounds.position.y,
			bounds.end.x - pile_left + 30.0, -bounds.position.y + 140))
	# The child camera connected in _ready() and updates its transform first.
	get_viewport().size_changed.connect(_layout_wallpaper_sky)
	_layout_wallpaper_sky()
	sync_state(state, true, transfer_facing)
	# Patrol along the front of the upper terrace, outside the quarry cut.
	overseer = SiteOverseer.new()
	overseer.planted_stance = true
	workers.add_child(overseer)
	var watched_workers: Array[Node2D] = [
		_views[Owner.MINER].root, _views[Owner.DRESSER].root, _views[Owner.BUILDER].root,
	]
	if configure_patrol.is_valid():
		configure_patrol.call(overseer, _geometry, watched_workers)
	else:
		overseer.setup([
			Vector2(pit_right + 80.0, 30.0),
			Vector2(screen_point(_geometry.workshop()).x - 65.0, 30.0),
			Vector2(left + 45.0, 30.0),
		], watched_workers, false)
	render_frame(1.0, 0.0)


func sync_state(state: State, snap: bool = false, transfer_facing: Dictionary = {}) -> void:
	var mined := state.mined_count()
	if mined > _mined:
		_update_quarry(mined)
	var placed := state.placed_count()
	for i in range(_placed, placed):
		pyramid.set_cell(_brick_cells[i], 0, Vector2i.ZERO)
	_placed = placed


	var ready_stones := state.stock(Owner.QUARRY)
	for i in range(_quarry_stones.size()):
		var stone := _quarry_stones[i]
		stone.visible = i < ready_stones.size()
		if stone.visible:
			stone.position = screen_point(_geometry.quarry_pickup(ready_stones[i], mined)) + Vector2(0, -17)

	_platform_after = screen_point(state.platform_position())
	if snap:
		_platform_before = _platform_after
	_row = state.current_row
	_finished = state.finished
	_rebuilding = state.worker(Owner.BUILDER).fsm_state == &"rebuild_platform"
	var target := clampi(placed - state.row_start, 0, _geometry.row_size(_row) - 1)
	var route := _geometry.builder_to_brick(_row, target)
	var builder := state.worker(Owner.BUILDER)
	var unloading := builder.fsm_state == &"unload_at_lift"
	var hauling_to_lift := builder.fsm_state == &"walk_to_lift_base"
	var placing := (builder.fsm_state == &"place_brick" or unloading) and state.stock_count(Owner.BUILDER) > 0
	var placement_center_x := INF
	var base_stock := state.stock_count(Owner.FINISHED)
	if snap or builder.fsm_state not in [&"walk_to_lift", &"return_from_lift"]:
		_builder_lift_stance = 0.0
	if unloading or hauling_to_lift:
		var drop: Sprite2D = _piles[Owner.FINISHED][base_stock]
		_builder_brick_target = drop.position
		placement_center_x = _builder_brick_target.x
		_builder_lift_stance = placement_center_x - _lift_base.x - BUILDER_PLACE_GRIP.x
	elif placing or builder.fsm_state == &"walk_to_brick":
		_builder_brick_target = _brick_center(placed)
		placement_center_x = _builder_brick_target.x
	elif builder.fsm_state == &"return_to_platform" or _finished:
		placement_center_x = _brick_center(placed - 1).x
	if placing:
		_placement_before = _placement_after
		var work := builder.phase_work()
		_placement_after = 1.0 - builder.remaining_work / work if work > 0.0 else 1.0
		# Show contact before the completion tick replaces the sprite with the tile.
		var work_per_tick := _step_seconds * builder.speed_multiplier
		if builder.remaining_work <= work_per_tick or is_equal_approx(builder.remaining_work, work_per_tick):
			_placement_after = 1.0
		if snap:
			_placement_before = _placement_after
	else:
		_placement_before = 0.0
		_placement_after = 0.0
	_crank_seconds_left = 0.0
	_deck_end = screen_point(route[-1]).x
	if builder.fsm_state == &"return_to_platform":
		var return_column := maxi(0, target - 1)
		# Count the laid brick before clamping to the row's last column.
		return_column = clampi(placed - state.row_start - 1, 0, _geometry.row_size(_row) - 1)
		_deck_end = screen_point(_geometry.builder_to_brick(_row, return_column)[-1]).x

	for owner in _piles:
		var count := state.stock_count(owner)
		var pool := _piles[owner]
		for i in range(pool.size()):
			pool[i].visible = i < count

	var next_unload_slot := {Owner.RAW: state.stock_count(Owner.RAW),
		Owner.QUARRY_STOCK: state.stock_count(Owner.QUARRY_STOCK),
		Owner.FINISHED: base_stock + int(unloading)}
	for id in state.worker_ids():
		if not _views.has(id):
			_views[id] = _create_worker(id)
		var view := _views[id]
		var worker := state.worker(id)
		var miner_sled := id == Owner.MINER
		var handles_sled: bool = view.has("transfer_item")
		view.quarry_haul = _geometry.quarry_slopes != null and (miner_sled or id >= Owner.FIRST_PORTER) \
			and state.transfer_source(id) == Owner.QUARRY
		view.cranking = worker.fsm_state == &"operate_lift"
		if view.cranking:
			_crank_seconds_left = worker.remaining_work
		var point := screen_point(worker.position)
		if view.has("walker"):
			var shift := 0.0
			var gap := point.distance_to(screen_point(_geometry.lift_operator_position()))
			var waiting_at_crank := id == Owner.MINER and gap < 0.1
			if view.cranking or waiting_at_crank:
				shift = CRANK_STANCE_SHIFT
			elif worker.fsm_state in [&"walk_to_lift", &"return_from_lift"]:
				shift = CRANK_STANCE_SHIFT * (1.0 - smoothstep(0.0, CRANK_STANCE_APPROACH, gap))
			view.crank_shift_before = shift if snap or view.fresh else view.get("crank_shift_after", 0.0)
			view.crank_shift_after = shift
		var placing_here := id == Owner.BUILDER and placing
		if id == Owner.BUILDER and is_finite(placement_center_x):
			if unloading or hauling_to_lift:
				var approach := maxf(BUILDER_LIFT_APPROACH, absf(_builder_lift_stance) * 1.6)
				point.x += _builder_lift_stance * (1.0 - smoothstep(0.0, approach, _lift_base.x - point.x))
			else:
				var gap := placement_center_x - point.x
				var offset := BUILDER_PLACE_GRIP.x * (1.0 - smoothstep(0.0, BUILDER_PLACEMENT_APPROACH, gap))
				if _pyramid_ramp != null and _row > 0:
					var entry := screen_point(_geometry.pyramid_deck_entry(_row))
					offset = clampf(offset, 0.0, maxf(0.0, point.x - entry.x))
				point.x -= offset
		elif id == Owner.BUILDER and builder.fsm_state == &"walk_to_lift" and _builder_lift_stance != 0.0:
			var crank_x := screen_point(_geometry.lift_operator_position()).x
			point.x += _builder_lift_stance * clampf(inverse_lerp(crank_x, _lift_base.x, point.x), 0.0, 1.0)
		elif id == Owner.BUILDER and builder.fsm_state == &"return_from_lift" and _builder_lift_stance != 0.0:
			var distance := builder.phase_distance_traveled() * PIXELS_PER_UNIT
			point.x += _builder_lift_stance * (1.0 - clampf(distance / 90.0, 0.0, 1.0))
		var direction := worker.segment_direction()
		var mining := false
		var strike_left := false
		if id == Owner.MINER:
			if worker.fsm_state == &"mine":
				var targets := state.task_resource_ids(id)
				mining = not targets.is_empty()
				if mining:
					strike_left = _geometry.quarry_grid_cell(targets[0]).x <= 0
					var stance := Vector2(MINER_STANCE.x * (1.0 if strike_left else -1.0),
						MINER_STANCE.y)
					if _geometry.quarry_slopes == null:
						point = _quarry_impact_point(targets[0]) + stance
		if id >= Owner.FIRST_PORTER and not view.cranking:
			point.y += (id - Owner.FIRST_PORTER) * 3
		view.before = view.after
		if snap or view.fresh or mining or (id == Owner.LIFT and state.stock_count(id) == 0):
			view.before = point
		view.fresh = false
		view.after = point
		view.active = worker.fsm_state in ACTIONS
		var count := state.stock_count(id)
		var composite_dresser := id == Owner.DRESSER and worker.fsm_state == &"process_brick"
		var transferring := false
		var carrying_brick := false
		if handles_sled:
			carrying_brick = state.transfer_source(id) == Owner.WORKSHOP_OUTPUT
			transferring = worker.fsm_state in [&"load", &"unload"]
			var texture := _art.brick if carrying_brick else _art.stone
			var item_scale := Vector2.ONE if carrying_brick else RAW_STONE_SCALE
			for item: Sprite2D in view.items:
				item.texture = texture
				item.scale = item_scale / view.sled.scale
		if view.has("walker"):
			var delta: Vector2 = point - view.before
			var distance := delta.length()
			var travel := delta / distance if distance >= 0.01 else Vector2.ZERO
			var previous: Vector2 = view.get("walk_travel", Vector2.ZERO)
			view.stride_starts = previous == Vector2.ZERO or not view.get("stride_continues", false) \
				or previous.dot(travel) < 0.0
			view.stride_continues = worker.remaining_distance > 0.0 \
				and travel.dot(screen_point(direction)) >= 0.0
			if snap and transferring:
				var saved: Variant = transfer_facing.get(str(id))
				if (saved is float or saved is int) and saved in [-1.0, 1.0]:
					view.facing = float(saved)
				else:
					view.facing = _legacy_transfer_facing(state, id)
			elif absf(delta.x) >= 0.01:
				view.facing = signf(travel.x)
			elif snap and absf(direction.x) > 0.01:
				view.facing = signf(direction.x)
			view.walk_start = fposmod(view.walk_end, 2.0) if travel != Vector2.ZERO else 0.5
			view.walk_end = view.walk_start
			if travel != Vector2.ZERO:
				var length := WorkerWalk.step_length(travel)
				view.walk_end += distance / (length * WORKER_FRAME_SCALE)
			view.walk_travel = travel
			if view.has("sled"):
				var tow_direction := screen_point(direction).normalized() if snap else travel
				if not is_zero_approx(tow_direction.x):
					view.tow_direction = tow_direction
			view.use_walker = id != Owner.DRESSER and not mining and not placing_here
			view.walking = worker.remaining_distance > 0.0
			view.empty_idle = id != Owner.DRESSER and count == 0 and worker.fsm_state in [&"idle", &"exhausted"]
		var body: Sprite2D = view.body
		var dresser_resting := id == Owner.DRESSER and worker.fsm_state == &"idle"
		if id == Owner.DRESSER:
			body.material = view.rest_material if dresser_resting else null
		if dresser_resting:
			_set_worker_frame(body, DRESSER_REST, DRESSER_REST_FEET, view.facing < 0.0)
		elif mining or composite_dresser:
			var action := "mine" if mining else "dress"
			var frame := floori(worker.remaining_work * 4.0) % 2
			if mining and worker.remaining_work <= _step_seconds * worker.speed_multiplier:
				frame = 0
			_set_worker_frame(body, _worker_frames[action][frame], SIMPLE_FRAMES[action][frame],
				strike_left if mining else view.facing < 0.0)
		elif placing_here or transferring:
			_set_worker_frame(body, BUILDER_PLACE, BUILDER_PLACE_FEET, false)
		elif id == Owner.MINER:
			body.texture = _art[WORKER_ART.get(id, "porter")]
			body.scale = Vector2.ONE
			body.offset = Vector2(0, -56)
			body.flip_h = view.facing < 0.0
		if handles_sled:
			body.position = Vector2.ZERO
			body.rotation = 0.0
		for i in range(view.items.size()):
			view.items[i].visible = i < count and not composite_dresser and not placing_here
		if id == Owner.BUILDER:
			view.placing = placing_here
			view.unloading = unloading
			view.ground_haul = worker.fsm_state == &"walk_to_lift_base"
		if view.has("sled"):
			view.sled.visible = transferring or (count > 0 and not placing_here)
		if handles_sled:
			view.transferring = transferring
			if transferring:
				view.tow_route = PackedVector2Array()
				_sync_porter_transfer(state, id, view, ready_stones, next_unload_slot, carrying_brick, snap)
			else:
				view.transfer_id = -1
				if count > 0 and worker.remaining_distance > 0.0:
					view.tow_route = worker.movement_route()
					view.tow_segment = worker.path_segment


func transfer_facing_snapshot() -> Dictionary:
	var facing := {}
	for id in _views:
		var view := _views[id]
		if view.get("transferring", false):
			facing[str(id)] = view.facing
	return facing


func _legacy_transfer_facing(state: State, id: int) -> float:
	var source := state.transfer_source(id)
	if state.worker(id).fsm_state == &"unload":
		if source == Owner.QUARRY_STOCK:
			return signf(_geometry.raw_storage().x - _geometry.quarry_stock().x)
		if source == Owner.WORKSHOP_OUTPUT:
			return signf(_geometry.finished_storage().x - _geometry.workshop_pickup().x)
		return 1.0
	if source == Owner.WORKSHOP_OUTPUT:
		return signf(_geometry.workshop_pickup().x - _geometry.raw_storage().x)
	if source == Owner.QUARRY_STOCK:
		return signf(_geometry.quarry_stock().x - _geometry.raw_storage().x)

	# Wallpaper quarry routes are monotone in X. A zero-length approach
	# leaves the view facing in the direction of the preceding walk.
	var pickup_x := state.worker(id).position.x
	var mined := state.mined_count()
	if id == Owner.MINER:
		for resource_id in range(mined - 1, -1, -1):
			var dx := pickup_x - _geometry.miner_work_position(resource_id, mined).x
			if not is_zero_approx(dx):
				return signf(dx)
	else:
		var cargo_ids := state.stock(id)
		for index in range(cargo_ids.size() - 1, -1, -1):
			var dx := pickup_x - _geometry.quarry_pickup(cargo_ids[index], mined).x
			if not is_zero_approx(dx):
				return signf(dx)
		return signf(pickup_x - _geometry.raw_storage().x)
	return 1.0


func _set_worker_frame(body: Sprite2D, texture: Texture2D, feet: Vector2, flip: bool) -> void:
	body.texture = texture
	body.scale = Vector2.ONE * WORKER_FRAME_SCALE
	body.flip_h = flip
	if flip:
		feet.x = texture.get_width() - feet.x
	body.offset = texture.get_size() * 0.5 - feet


func _sync_porter_transfer(state: State, id: int, view: Dictionary, ready_stones: Array,
		next_unload_slot: Dictionary, carrying_brick: bool, snap: bool) -> void:
	var worker := state.worker(id)
	var loading := worker.fsm_state == &"load"
	# Remove the topmost piece first so earlier slots stay in place.
	var slot_index := state.stock_count(id) - int(not loading)
	var slot: Sprite2D = view.items[slot_index]
	var ground: Sprite2D
	var resource_id: int
	if loading:
		resource_id = state.pickup_targets(id)[0]
		match state.transfer_source(id):
			Owner.WORKSHOP_OUTPUT:
				ground = _piles[Owner.WORKSHOP_OUTPUT][state.stock(Owner.WORKSHOP_OUTPUT).find(resource_id)]
			Owner.QUARRY_STOCK:
				ground = _piles[Owner.QUARRY_STOCK][state.stock(Owner.QUARRY_STOCK).find(resource_id)]
			_:
				ground = _quarry_stones[ready_stones.find(resource_id)]
		ground.hide()
	else:
		resource_id = state.stock(id)[-1]
		var destination := Owner.RAW
		if id == Owner.MINER:
			destination = Owner.QUARRY_STOCK
		elif carrying_brick:
			destination = Owner.FINISHED
		ground = _piles[destination][next_unload_slot[destination]]
		next_unload_slot[destination] += 1
		slot.hide()
	var work := worker.phase_work()
	var progress := clampf(1.0 - worker.remaining_work / work, 0.0, 1.0) if work > 0.0 else 1.0
	if worker.remaining_work <= _step_seconds * worker.speed_multiplier:
		progress = 1.0
	var same_transfer: bool = view.transfer_id == resource_id and view.loading == loading
	if snap or not same_transfer:
		view.sled.rotation = 0.0
		view.sled.position = Vector2(-view.facing * PORTER_SLED_DISTANCE, 0)
		view.sled.flip_h = view.facing < 0.0
	view.transfer_before = progress if snap else (view.transfer_after if same_transfer else 0.0)
	view.transfer_after = progress
	view.transfer_id = resource_id
	view.loading = loading
	view.transfer_ground = ground.position
	view.transfer_ground_scale = ground.scale
	view.transfer_sled = slot.position * view.sled.scale
	view.transfer_sled_scale = slot.scale * view.sled.scale
	var item: Sprite2D = view.transfer_item
	item.texture = slot.texture


func _render_porter_transfer(view: Dictionary, fraction: float) -> void:
	var item: Sprite2D = view.transfer_item
	item.show()
	var root: Node2D = view.root
	var sled: Sprite2D = view.sled
	var ground: Vector2 = view.transfer_ground - root.position
	var on_sled: Vector2 = sled.position + view.transfer_sled
	var progress := lerpf(view.transfer_before, view.transfer_after, fraction)
	# Unloading runs the same reach, lift and set-down in reverse.
	var across := smoothstep(0.06, 0.94, progress if view.loading else 1.0 - progress)
	var toward_sled := signf(on_sled.x - ground.x)
	if is_zero_approx(toward_sled):
		toward_sled = -view.facing
	var turn := smoothstep(0.35, 0.65, across) * 2.0 - 1.0
	var facing := toward_sled if turn >= 0.0 else -toward_sled
	var body: Sprite2D = view.body
	if body.flip_h != (facing < 0.0):
		_set_worker_frame(body, BUILDER_PLACE, BUILDER_PLACE_FEET, facing < 0.0)
	item.position = ground.lerp(on_sled, across)
	var lift := sin(PI * across)
	item.position.y -= 16.0 * lift
	var ground_scale: Vector2 = view.transfer_ground_scale
	item.scale = ground_scale.lerp(view.transfer_sled_scale, across)
	# Turn with the piece in front of the body, and pivot the reach around the feet.
	var width := lerpf(0.40, 1.0, absf(turn))
	body.scale.x = WORKER_FRAME_SCALE * width
	var reach_height := smoothstep(24.0, 70.0, -item.position.y)
	body.rotation = facing * lerpf(0.17, -0.50, reach_height)
	var grip := Vector2(BUILDER_PLACE_GRIP.x * facing * width, BUILDER_PLACE_GRIP.y).rotated(body.rotation)
	body.position.x = item.position.x - grip.x


func capture_tick(state: State) -> void:
	_platform_before = _platform_after
	sync_state(state)


func render_frame(fraction: float, game_seconds: float) -> void:
	var point := _platform_before.lerp(_platform_after, fraction)
	_platform.position = point
	_platform.visible = _row > 0 or _rebuilding
	var cranking := _crank_seconds_left > 0.0
	if cranking:
		var duration := _geometry.lift_seconds(_row)
		var elapsed := maxf(0.0, duration - _crank_seconds_left - _step_seconds * (1.0 - fraction))
		_crank.rotation = TAU * ceilf(duration * 1.25) * elapsed / duration
	else:
		_crank.rotation = 0.0
	var lift_base := _lift_base
	_pulley.position = Vector2(lift_base.x, point.y - 69)
	if _upper_cable != null:
		var cable_y := -_geometry.lift_cable_height(_row) * PIXELS_PER_UNIT
		var right := _geometry.pyramid_right() * PIXELS_PER_UNIT
		_upper_cable.set_point_position(0, Vector2(lift_base.x, cable_y))
		_upper_cable.set_point_position(1, Vector2(right, cable_y))
		_cable_support.position = Vector2(right, cable_y * 0.5)
		_cable_support.scale.y = -cable_y / 64.0
		_pulley.position.y = cable_y
	_mast.position = Vector2(lift_base.x, (_pulley.position.y + lift_base.y) * 0.5)
	_mast.scale.y = (lift_base.y - _pulley.position.y) / 64.0
	var deck_y := point.y - (_brick_height if _row > 0 else 0.0)
	_deck.visible = _row > 0 and (not _finished or _pyramid_ramp != null) and not _rebuilding
	var deck_start := point.x - (124.0)
	if _pyramid_ramp != null:
		var entry := screen_point(_geometry.pyramid_deck_entry(_row))
		deck_start = entry.x
		deck_y = entry.y
		var tip := entry
		if _rebuilding:
			tip = screen_point(_geometry.platform(_row + 1))
		_pyramid_ramp.visible = _row > 0 or _rebuilding
		var thickness := Vector2(0, 12)
		_pyramid_ramp.polygon = PackedVector2Array([lift_base, tip, tip + thickness, lift_base + thickness])
	_deck.position = Vector2((deck_start + _deck_end) * 0.5, deck_y + 7)
	_deck.scale.x = maxf(0, _deck_end - deck_start) / 64.0
	if _platform_pile_anchor != point:
		_platform_pile_anchor = point
		var brick := _art.brick.get_size()
		_update_pile(Owner.PLATFORM, point, 3, brick.x, brick.y)

	var animation_seconds := maxf(0.0, game_seconds - (1.0 - fraction) * _step_seconds)
	for id in _views:
		var view := _views[id]
		var root: Node2D = view.root
		root.position = view.before.lerp(view.after, fraction)
		var on_ramp := false
		if id == Owner.BUILDER and _pyramid_ramp != null and not is_equal_approx(view.before.y, view.after.y):
			# A tick can straddle either end of the incline. Follow the surface
			# through that joint instead of cutting the corner with a chord.
			var step := screen_point(_geometry.pyramid_ramp_step())
			var y := lift_base.y + (root.position.x - lift_base.x) * step.y / step.x
			var high := minf(view.before.y, view.after.y)
			var low := maxf(view.before.y, view.after.y)
			root.position.y = clampf(y, high, low)
			on_ramp = y >= high and y <= low
		if view.quarry_haul:
			root.position.y = _quarry_surface_screen_y(root.position.x, id == Owner.MINER)
		elif id == Owner.MINER and _geometry.quarry_slopes != null:
			var feet := root.position * Vector2(1, -1) / PIXELS_PER_UNIT
			root.position = screen_point(_geometry.quarry_slopes.project(feet, _mined))
		var transferring: bool = view.get("transferring", false)
		var walker: WorkerWalk = view.get("walker")
		var pulling := false
		if view.has("sled") and view.sled.visible and not transferring:
			pulling = id != Owner.BUILDER or view.ground_haul or root.position.y <= deck_y + 0.5
		if walker != null:
			var crank_arrival_tolerance := 0.1
			var at_crank: bool = view.cranking and root.position.distance_to(view.after) < crank_arrival_tolerance
			root.position.x += lerpf(view.crank_shift_before, view.crank_shift_after, fraction)
			var travel: Vector2 = view.walk_travel
			if id == Owner.BUILDER and _pyramid_ramp != null and travel != Vector2.ZERO:
				var tangent := screen_point(_geometry.pyramid_ramp_step()).normalized()
				travel = (tangent if on_ramp else Vector2.RIGHT) * signf(travel.x)
			var moving := travel != Vector2.ZERO
			# Finish the displayed movement before switching to the new action.
			var in_step: bool = moving and (view.walking or fraction < 1.0)
			var resting: bool = view.empty_idle and not in_step
			var moving_dresser: bool = id == Owner.DRESSER and (view.walking or view.cranking)
			if resting and id >= Owner.FIRST_PORTER:
				pulling = false
			walker.visible = not transferring \
				and (view.use_walker or view.empty_idle or moving_dresser or at_crank or (in_step and not view.get("placing", false)))
			view.body.visible = not walker.visible
			if walker.visible:
				if at_crank:
					walker.grip_crank(_crank_grip.global_position, true)
				elif resting:
					walker.pose_idle(animation_seconds + id * 0.81, view.facing)
				else:
					var stride_weight := 1.0
					if in_step:
						if view.stride_starts:
							stride_weight = smoothstep(0.0, 1.0, fraction)
						if not view.stride_continues:
							stride_weight = minf(stride_weight, 1.0 - smoothstep(0.0, 1.0, fraction))
					walker.pose(lerpf(view.walk_start, view.walk_end, fraction),
						travel if in_step else Vector2.ZERO, view.facing, pulling, stride_weight)
		if id == Owner.DRESSER and view.body.material != null:
			view.rest_material.set_shader_parameter("phase", animation_seconds * TAU / 3.8)
		if id == Owner.BUILDER:
			_placing_brick.visible = view.placing
			if view.placing:
				var progress := lerpf(_placement_before, _placement_after, fraction)
				var held_center := root.position + BUILDER_PLACE_GRIP + Vector2(0, 4)
				var release := smoothstep(0.55, 0.9, progress)
				_placing_brick.position = held_center.lerp(_builder_brick_target, release)
				_placing_brick.z_index = cargo.z_index if view.unloading else pyramid.z_index
		if view.has("sled") and view.sled.visible and not transferring:
			_update_sled(id, view, pulling, walker)
		elif view.has("tether"):
			view.tether.hide()
		if transferring:
			_render_porter_transfer(view, fraction)
		elif view.has("transfer_item"):
			view.transfer_item.hide()
		if id == Owner.LIFT:
			var loaded: bool = view.items[0].visible
			_rope.visible = loaded
			view.body.visible = loaded and _upper_cable == null
			var rope_end := root.position + Vector2(0, -9)
			if _upper_cable != null:
				_pulley.position.x = maxf(lift_base.x, root.position.x)
				rope_end = root.position - Vector2(0, _brick_height)
			if _rope.get_point_position(0) != _pulley.position:
				_rope.set_point_position(0, _pulley.position)
			if _rope.get_point_position(1) != rope_end:
				_rope.set_point_position(1, rope_end)
		else:
			var pulse := (0.5 + 0.5 * sin(game_seconds * 17.0)) if view.active else 0.0
			var tint := Color.WHITE.lerp(Color(1.10, 1.04, 0.97), pulse)
			view.body.modulate = tint
			if walker != null:
				walker.modulate = tint

	overseer.render(animation_seconds, _finished)


func _update_sled(id: int, view: Dictionary, pulling: bool, walker: WorkerWalk) -> void:
	var sled: Sprite2D = view.sled
	var tether: Line2D = view.tether
	var distance := PORTER_SLED_DISTANCE
	if id == Owner.BUILDER:
		# The interpolated feet can still be climbing after the model enters the deck.
		sled.self_modulate.a = 1.0 if pulling else 0.0
		distance = 68.0 if pulling else 20.0
	tether.visible = pulling
	var direction: Vector2 = view.tow_direction if pulling else Vector2(view.facing, 0)
	var facing := signf(direction.x)
	sled.position = -direction * distance
	sled.flip_h = facing < 0.0
	# The sled stays upright when the carrier heads left.
	sled.rotation = (direction * facing).angle()
	if not tether.visible:
		return
	var route: PackedVector2Array = view.tow_route
	if view.quarry_haul:
		var worker_x: float = view.root.position.x
		var center_x := worker_x - facing * distance
		var reach := sled.texture.get_width() * sled.scale.x * 0.4
		var left_y := _quarry_surface_screen_y(center_x - reach, id == Owner.MINER)
		var right_y := _quarry_surface_screen_y(center_x + reach, id == Owner.MINER)
		sled.position = Vector2(center_x - worker_x, (left_y + right_y) * 0.5 - view.root.position.y)
		sled.rotation = Vector2(2.0 * reach, right_y - left_y).angle()
	elif not route.is_empty():
		_fit_sled_to_route(sled, route, view.tow_segment, view.root.position.x, facing, distance)
	var hitch_offset := WALLPAPER_SLED_HITCH
	var hitch := sled.position + Vector2(facing * hitch_offset.x, hitch_offset.y).rotated(sled.rotation)
	var hand := walker.hand_position if walker.visible else Vector2(-view.facing * 22, -37)
	tether.set_point_position(0, hand)
	tether.set_point_position(1, hitch)


func _quarry_surface_screen_y(screen_x: float, to_quarry_stock := false) -> float:
	var storage := _geometry.quarry_stock() if to_quarry_stock else _geometry.raw_storage()
	return -PIXELS_PER_UNIT * _geometry.quarry_slopes.surface_y(
		screen_x / PIXELS_PER_UNIT, _mined, storage)


func _fit_sled_to_route(sled: Sprite2D, route: PackedVector2Array, segment: int,
		worker_x: float, facing: float, distance: float) -> void:
	var center_x := worker_x - facing * distance
	var reach := sled.texture.get_width() * sled.scale.x * 0.4
	var left_y := _tow_surface_y(route, segment, facing, center_x - reach)
	var right_y := _tow_surface_y(route, segment, facing, center_x + reach)
	var worker_y := _tow_surface_y(route, segment, facing, worker_x)
	sled.position = Vector2(center_x - worker_x, (left_y + right_y) * 0.5 - worker_y)
	sled.rotation = Vector2(2.0 * reach, right_y - left_y).angle()


func _tow_surface_y(route: PackedVector2Array, segment: int, facing: float, screen_x: float) -> float:
	var x := screen_x / PIXELS_PER_UNIT
	for index in range(segment, -1, -1):
		var start := route[index]
		var finish := route[index + 1]
		if (finish.x - start.x) * facing <= 0.0:
			# After a turn the team pulls away from this point on its new side.
			return -finish.y * PIXELS_PER_UNIT
		if (x - start.x) * facing >= 0.0:
			var weight := clampf(inverse_lerp(start.x, finish.x, x), 0.0, 1.0)
			return -lerpf(start.y, finish.y, weight) * PIXELS_PER_UNIT
	# The sled starts on the level of the pickup before it reaches the slope.
	return -route[0].y * PIXELS_PER_UNIT


func play_production(events: Array[Dictionary]) -> void:
	for event in events:
		var effect: StringName
		match event.state:
			&"place_brick":
				if not event.has("placement_index"):
					continue
				effect = &"placement_dust"
			&"mine":
				if not event.has("resource_id"):
					continue
				effect = &"dust"
			&"process_brick":
				effect = &"dust"
			_:
				continue
		var sprite := _effects[effect]
		if _effect_tweens.has(effect):
			_effect_tweens[effect].kill()
		if event.state == &"mine":
			sprite.position = _quarry_impact_point(event.resource_id)
		elif event.state == &"place_brick":
			sprite.position = _brick_center(event.placement_index) - Vector2(0, _brick_height * 0.5)
		else:
			var worker: Node2D = _views[event.worker_id].root
			sprite.position = worker.position + Vector2(22, -22)
		sprite.scale = Vector2.ONE * 0.65
		sprite.modulate.a = 0.85
		sprite.show()
		var tween := create_tween().set_parallel()
		_effect_tweens[effect] = tween
		tween.tween_property(sprite, "position", sprite.position + Vector2(12, -18), 0.24)
		tween.tween_property(sprite, "modulate:a", 0.0, 0.24)
		tween.chain().tween_callback(sprite.hide)


func _create_worker(id: int) -> Dictionary:
	var root := Node2D.new()
	workers.add_child(root)
	var body: Sprite2D
	if id != Owner.LIFT:
		body = Sprite2D.new()
		root.add_child(body)
	else:
		body = _sprite("lift_cradle" if id == Owner.LIFT else WORKER_ART.get(id, "porter"), root)
	body.offset = Vector2(0, 15 if id == Owner.LIFT else -56)
	var items: Array[Sprite2D] = []
	var view := {"root": root, "body": body, "items": items, "fresh": true,
		"before": Vector2.ZERO, "after": Vector2.ZERO, "facing": 1.0, "active": false}
	if id == Owner.DRESSER:
		var rest_material := ShaderMaterial.new()
		rest_material.shader = DRESSER_REST_SHADER
		view.rest_material = rest_material
	if id != Owner.LIFT:
		var walker := WorkerWalk.new()
		walker.planted_stance = true
		walker.scale = Vector2.ONE * WORKER_FRAME_SCALE
		root.add_child(walker)
		view.walker = walker
		view.walk_end = 0.5
	if id >= Owner.FIRST_PORTER or (id in [Owner.BUILDER, Owner.MINER]):
		var tether := Line2D.new()
		tether.width = 3
		tether.default_color = Color("#694b35")
		tether.points = PackedVector2Array([Vector2.ZERO, Vector2.ZERO])
		root.add_child(tether)
		view.tether = tether
		var sled := _sprite("sled", root)
		sled.scale = Vector2(0.85, 0.45)
		sled.offset.y = -16
		view.sled = sled
		view.tow_direction = Vector2.RIGHT
		view.tow_route = PackedVector2Array()
		if id == Owner.BUILDER:
			var brick := _sprite("brick", sled)
			brick.position = Vector2(0, -55)
			brick.scale = Vector2(1.0 / sled.scale.x, 1.0 / sled.scale.y)
			items.append(brick)
		else:
			var capacity := 1 if id == Owner.MINER else State.MAX_PORTER_CAPACITY
			for i in range(capacity):
				var stone := _sprite("stone", sled)
				stone.scale = RAW_STONE_SCALE / sled.scale
				@warning_ignore("integer_division")
				var row := i / PORTER_SLED_COLUMNS
				var column := i % PORTER_SLED_COLUMNS
				var base_y := -74.0
				stone.position = Vector2((column - 1) * PORTER_SLED_COLUMN_SPACING,
					base_y - row * PORTER_SLED_ROW_RISE)
				if id == Owner.MINER:
					stone.position.x = 0.0
				items.append(stone)
			view.transfer_id = -1
			view.loading = false
			view.transfer_item = _sprite("stone", root)
			root.move_child(body, -1)
	else:
		var item := _sprite("stone" if id in [Owner.MINER, Owner.DRESSER] else "brick", root)
		item.position = Vector2(24, -43)
		if id == Owner.LIFT:
			item.position = Vector2(0, -23)
			if _geometry.has_upper_delivery():
				item.position = Vector2(0, -14)
		if id == Owner.BUILDER:
			item.scale = Vector2.ONE * 0.75
		items.append(item)
	return view


func _update_pile(owner: int, anchor: Vector2, columns: int, spacing: float, rise: float) -> void:
	var pool := _piles[owner]
	var center_height := _brick_height * 0.5
	if owner == Owner.RAW:
		center_height = 16.0
	elif owner == Owner.QUARRY_STOCK:
		center_height = 11.0
	for i in range(pool.size()):
		var item: Sprite2D = pool[i]
		item.position = anchor + Vector2((i % columns - (columns - 1) * 0.5) * spacing,
			-center_height - floori(float(i) / columns) * rise)


func _winch_line(parent: Node2D, points: PackedVector2Array, width: float, color: Color) -> Line2D:
	var line := Line2D.new()
	line.points = points
	line.width = width
	line.default_color = color
	line.antialiased = true
	line.joint_mode = Line2D.LINE_JOINT_ROUND
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode = Line2D.LINE_CAP_ROUND
	parent.add_child(line)
	return line


func _create_terraces(rect: Rect2) -> void:
	_foreground_rect = rect
	var back := _sand_polygon(Color.WHITE, -7)
	var back_rect := Rect2(rect.position.x, 0, rect.size.x, rect.position.y + 3)
	var back_outline := PackedVector2Array([
		back_rect.position, Vector2(back_rect.end.x, 0), back_rect.end,
		Vector2(back_rect.position.x, back_rect.end.y),
	])
	_set_sand_outline(back, back_outline)
	_quarry_cut = _sand_polygon(Color("#685248"), -6)
	_foreground = _sand_polygon(Color("#d3c0aa"), -5)
	_quarry_rim = Line2D.new()
	_quarry_rim.width = 2.0
	_quarry_rim.default_color = Color("#b39473")
	_quarry_rim.z_index = -4
	add_child(_quarry_rim)
	_set_sand_outline(_foreground, PackedVector2Array([
		rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y),
	]))


func _sand_polygon(tint: Color, depth: int) -> Polygon2D:
	var sand := Polygon2D.new()
	sand.texture = WALLPAPER_SAND
	sand.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	sand.color = tint
	sand.z_index = depth
	add_child(sand)
	return sand


func _set_sand_outline(sand: Polygon2D, points: PackedVector2Array) -> void:
	var uv := PackedVector2Array()
	for point in points:
		uv.append(point / SAND_SCALE)
	sand.polygon = points
	sand.uv = uv


func _update_quarry(mined: int) -> void:
	_mined = mined
	var left_wall := PackedVector2Array()
	if _geometry.quarry_slopes != null:
		for point in _geometry.quarry_slopes.outline(mined):
			left_wall.append(screen_point(point))
	else:
		var right_wall := PackedVector2Array()
		for layer in range(_geometry.quarry_depth(mined) + 2):
			left_wall.append(screen_point(_geometry.quarry_edge(layer, -1, mined)))
			right_wall.append(screen_point(_geometry.quarry_edge(layer, 1, mined)))
		right_wall.reverse()
		left_wall.append_array(right_wall)
	_set_sand_outline(_quarry_cut, left_wall)
	_quarry_rim.points = left_wall
	var rect := _foreground_rect
	var sand_outline := PackedVector2Array([rect.position])
	sand_outline.append_array(left_wall)
	sand_outline.append_array(PackedVector2Array([
		Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y),
	]))
	_set_sand_outline(_foreground, sand_outline)


func _quarry_impact_point(id: int) -> Vector2:
	var cell := _geometry.quarry_grid_cell(id)
	if _geometry.quarry_slopes != null:
		var stance := Vector2(MINER_STANCE.x * (1.0 if cell.x <= 0 else -1.0), MINER_STANCE.y)
		return screen_point(_geometry.miner_work_position(id, id)) - stance
	if cell.x == 0:
		return screen_point(_geometry.quarry_grid_point(cell))
	var edge := Vector2(float(cell.x) - signf(cell.x) * 0.5, cell.y + 0.8)
	return screen_point(_geometry.quarry_grid_point(edge))


func _make_brick_tiles(size: Vector2i, origin: Vector2) -> void:
	var atlas := TileSetAtlasSource.new()
	atlas.texture = _art.brick
	atlas.texture_region_size = Vector2i(atlas.texture.get_size())
	atlas.create_tile(Vector2i.ZERO)
	atlas.create_alternative_tile(Vector2i.ZERO, 1)
	atlas.get_tile_data(Vector2i.ZERO, 1).modulate = Color(0.85, 0.75, 0.62, 0.18)
	var tiles := TileSet.new()
	tiles.tile_size = size
	tiles.add_source(atlas, 0)
	pyramid.tile_set = tiles
	pyramid.position = origin


func _brick_center(placement_index: int) -> Vector2:
	return pyramid.position + pyramid.map_to_local(_brick_cells[placement_index])


func _sprite(name: String, parent: Node2D) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.texture = _art[name]
	if name == "stone":
		sprite.scale = RAW_STONE_SCALE
	parent.add_child(sprite)
	return sprite


func _prop(name: String, point: Vector2) -> Sprite2D:
	var sprite := _sprite(name, self)
	sprite.position = screen_point(point)
	sprite.offset.y = -sprite.texture.get_height() * 0.5
	return sprite


func _create_sky() -> void:
	_sky_material = ShaderMaterial.new()
	_sky_material.shader = SKY_SHADER
	_sky_material.set_shader_parameter("night_texture",
		load(SKY_ASSETS + "pixel_desert_night_aligned_1920x1080.png"))
	_sky_material.set_shader_parameter("morning_texture",
		load(SKY_ASSETS + "pixel_desert_morning_1920x1080.png"))
	_sky_material.set_shader_parameter("evening_texture",
		load(SKY_ASSETS + "pixel_desert_evening_1920x1080.png"))
	_sky_background = Sprite2D.new()
	_sky_background.texture = load(SKY_ASSETS + "pixel_desert_day_1920x1080.png")
	_sky_background.material = _sky_material
	_sky_background.z_index = -13
	add_child(_sky_background)
	# The visible disk occupies about 42% of the transparent canvas.
	_sun = _sky_object("sun.png", 335.0)
	_sun.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var sun_shader := Shader.new()
	sun_shader.code = """
shader_type canvas_item;
render_mode unshaded;
uniform float haze = 0.0;
varying vec4 sprite_modulate;

void vertex() {
	sprite_modulate = COLOR;
}

vec4 premultiply(vec4 sample_color) {
	return vec4(sample_color.rgb * sample_color.a, sample_color.a);
}

void fragment() {
	float spread = mix(0.006, 0.010, haze);
	vec2 offset = vec2(spread, 0.0);
	vec4 blurred = premultiply(texture(TEXTURE, UV)) * 0.52;
	blurred += (premultiply(texture(TEXTURE, UV + offset)) + premultiply(texture(TEXTURE, UV - offset))
		+ premultiply(texture(TEXTURE, UV + offset.yx)) + premultiply(texture(TEXTURE, UV - offset.yx))) * 0.12;
	vec3 rgb = blurred.rgb / max(blurred.a, 0.0001);
	rgb *= mix(vec3(1.0), vec3(1.0, 0.96, 0.90), haze);
	float halo_opacity = mix(0.72, 1.0, smoothstep(0.0, 0.80, blurred.a));
	COLOR = vec4(rgb, blurred.a * halo_opacity * (1.0 - 0.12 * haze)) * sprite_modulate;
}
"""
	var sun_material := ShaderMaterial.new()
	sun_material.shader = sun_shader
	_sun.material = sun_material
	_moon = _sky_object("moon.png", 190.0)
	_moon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var phase_shader := Shader.new()
	phase_shader.code = """
shader_type canvas_item;
render_mode unshaded;
uniform vec3 light_direction;
uniform float night_mix = 0.0;
uniform float atmospheric_clarity = 1.0;
uniform vec2 disc_center;
uniform float disc_radius;

void fragment() {
	vec2 disc = (UV - disc_center) / disc_radius;
	float depth = sqrt(max(0.0, 1.0 - dot(disc, disc)));
	float light = smoothstep(-0.045, 0.045, dot(vec3(disc, depth), light_direction));
	float detail = dot(COLOR.rgb, vec3(0.2126, 0.7152, 0.0722));
	vec3 lit_color = mix(vec3(0.70, 0.74, 0.79), vec3(1.0, 0.98, 0.94), detail);
	vec3 shadow_color = lit_color * 0.5;
	float day_opacity = mix(0.44, 0.72, atmospheric_clarity);
	float night_opacity = mix(0.73, 0.95, atmospheric_clarity);
	float lit_opacity = mix(day_opacity, night_opacity, night_mix) * light;
	// Scattered daylight fills the dark portion. A trace of earthshine remains at night.
	float shadow_opacity = night_mix * mix(0.03, 0.14, atmospheric_clarity) * (1.0 - light);
	float opacity = lit_opacity + shadow_opacity;
	COLOR.rgb = (lit_color * lit_opacity + shadow_color * shadow_opacity) / max(opacity, 0.0001);
	COLOR.a *= opacity * (1.0 - smoothstep(0.96, 1.02, length(disc)));
}
"""
	var phase_material := ShaderMaterial.new()
	phase_material.shader = phase_shader
	phase_material.set_shader_parameter("disc_center", MOON_DISC_CENTER)
	phase_material.set_shader_parameter("disc_radius", MOON_DISC_RADIUS)
	_moon.material = phase_material
	_stars = Node2D.new()
	var star_material := CanvasItemMaterial.new()
	star_material.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	_stars.material = star_material
	_stars.z_index = -10
	_stars.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	for style in STAR_STYLES:
		_star_textures.append(load(SKY_ASSETS + style.file))
	add_child(_stars)
	_stars.draw.connect(_draw_stars)


func _layout_wallpaper_sky() -> void:
	var camera: Camera2D = $Camera2D
	var size := get_viewport_rect().size / camera.zoom
	var origin := camera.position - size * 0.5
	# Keep the projected horizon above the hills in the original backgrounds.
	_sky_area = Rect2(origin, Vector2(size.x, size.y * 0.67))
	var native := _sky_background.texture.get_size()
	_sky_background.scale = Vector2.ONE * maxf(size.x / native.x, size.y / native.y)
	_sky_background.position = origin + size * 0.5
	_stars.queue_redraw()
	wallpaper_sky_area_changed.emit()


func wallpaper_sky_area() -> Rect2:
	return _sky_area


func _draw_stars() -> void:
	var zoom_factor: float = $Camera2D.zoom.x
	var moon_size := _moon.texture.get_size() * _moon.scale
	var moon_center := _moon.position + (MOON_DISC_CENTER - Vector2(0.5, 0.5)) * moon_size
	var moon_radius := MOON_DISC_RADIUS * moon_size.x
	var moon_opacity := _moon.self_modulate.a if _moon.visible else 0.0
	for star in _star_points:
		var point := Vector2(star.x, star.y)
		var opacity := _sky_visibility(point, 0.02)
		var center := _sky_area.position + point * _sky_area.size
		if moon_opacity > 0.0:
			var distance := center.distance_to(moon_center)
			var visible_fraction := smoothstep(moon_radius * 0.96, moon_radius * 1.02, distance)
			opacity *= lerpf(1.0, visible_fraction, moon_opacity)
		if opacity <= 0.0:
			continue
		var brightness := clampf((4.8 - star.z) / 4.0, 0.19, 1.0)
		for index in STAR_STYLES.size():
			var style: Dictionary = STAR_STYLES[index]
			if star.z <= style.max_magnitude:
				var region: Rect2 = style.region
				var size := region.size * (float(style.height_px) / (region.size.y * zoom_factor))
				_stars.draw_texture_rect_region(_star_textures[index], Rect2(center - size * 0.5, size),
					region, Color(1.0, 1.0, 1.0, brightness * opacity))
				break


func _sky_object(file: String, width: float) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.texture = load(SKY_ASSETS + file)
	sprite.scale = Vector2.ONE * width / sprite.texture.get_width()
	sprite.z_index = -10
	add_child(sprite)
	return sprite


func _sky_body_position(point: Vector2) -> Vector2:
	# Give low arcs and the southern sky more room while keeping the horizon,
	# zenith and azimuth boundaries fixed.
	var azimuth := 2.0 * point.x - 1.0
	var azimuth_spread := signf(azimuth) * log(1.0 + 5.0 * absf(azimuth)) / log(6.0)
	var height := maxf(0.0, 1.0 - point.y)
	var height_spread := log(1.0 + 16.0 * height) / log(17.0)
	var projected := Vector2(0.5 + 0.5 * azimuth_spread, 1.0 - height_spread)
	return _sky_area.position + projected * _sky_area.size


func update_sky(palette: Vector4, sun_point: Vector2, star_points: PackedVector3Array,
		star_opacity: float, celestial_opacity: float) -> void:
	_sky_material.set_shader_parameter("palette", palette)
	(_moon.material as ShaderMaterial).set_shader_parameter("night_mix", palette.x)
	_update_sky_body(_sun, sun_point, celestial_opacity)
	var sun_haze := 1.0 - smoothstep(0.0, 12.0 / 90.0, 1.0 - sun_point.y)
	(_sun.material as ShaderMaterial).set_shader_parameter("haze", sun_haze)
	_star_points = star_points
	_stars.self_modulate.a = star_opacity * celestial_opacity
	_stars.visible = _stars.self_modulate.a > 0.0
	if _stars.visible:
		_stars.queue_redraw()


func update_moon(point: Vector2, light_direction: Vector3, celestial_opacity := 1.0) -> void:
	_update_sky_body(_moon, point, celestial_opacity)
	var material := _moon.material as ShaderMaterial
	material.set_shader_parameter("light_direction", light_direction)
	# Use the altitude before projection stretches the low arc.
	material.set_shader_parameter("atmospheric_clarity", smoothstep(0.0, 0.27, 1.0 - point.y))


func _update_sky_body(sprite: Sprite2D, point: Vector2, celestial_opacity: float) -> void:
	sprite.position = _sky_body_position(point)
	sprite.self_modulate.a = _sky_visibility(point, BODY_HORIZON_FADE) * celestial_opacity
	sprite.visible = sprite.self_modulate.a > 0.0


static func _sky_visibility(point: Vector2, horizon_fade: float) -> float:
	var edge_distance := minf(point.x, 1.0 - point.x)
	return smoothstep(0.0, SKY_EDGE_FADE, edge_distance) \
		* (1.0 - smoothstep(1.0 - horizon_fade, 1.0, point.y))
