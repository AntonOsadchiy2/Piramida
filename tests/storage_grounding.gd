extends SceneTree

const WorldPresenter = preload("res://scripts/presentation/world_presenter.gd")
const Geometry = preload("res://scripts/domain/world_geometry.gd")
const State = preload("res://scripts/domain/game_state.gd")


func _init() -> void:
	var presenter := WorldPresenter.new()
	_check(presenter, "res://assets/sprites/stone.png", Vector2.ONE * 0.94 * 4.0)
	_check(presenter, "res://assets/sprites/brick.png", Vector2.ONE * 4.0)
	_check_finished_stack(presenter)
	presenter.free()
	print("PASS: storage sprites rest on their visible bottom edge")
	quit()


func _check_finished_stack(presenter: WorldPresenter) -> void:
	var balance: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance.json"))
	var blocks: Array[Dictionary] = [
		{"x": 0, "y": 0, "size": 4}, {"x": 4, "y": 0, "size": 2},
	]
	balance.world.blueprintBlocks = blocks
	var geometry := Geometry.new(balance)
	presenter._geometry = geometry
	presenter._art.stone = load("res://assets/sprites/limestone_1x1.png")
	presenter._art["stone_2x2"] = load("res://assets/sprites/limestone_2x2.png")
	presenter._art["stone_4x4"] = load("res://assets/sprites/limestone_4x4.png")
	presenter._lift_base = presenter.screen_point(geometry.finished_storage())
	var brick: Texture2D = load("res://assets/sprites/brick.png")
	var pool: Array[Sprite2D] = []
	for index in range(2):
		var sprite := Sprite2D.new()
		sprite.texture = brick
		presenter.add_child(sprite)
		pool.append(sprite)
	presenter._piles[State.Owner.FINISHED] = pool

	presenter._layout_finished_stock([0], 1)
	var first := _visible_box(pool[0])
	var second := _visible_box(pool[1])
	var raw_right := geometry.raw_storage_bounds().y * WorldPresenter.PIXELS_PER_UNIT
	var masonry_left: Vector2 = geometry.brick_origin(0, 0)
	assert(first.position.x > raw_right and second.position.x > raw_right)
	assert(first.end.x < presenter.screen_point(masonry_left).x)
	assert(is_equal_approx(first.end.y, presenter._lift_base.y))
	assert(is_equal_approx(second.end.y, first.position.y))

	var drop_point := pool[1].position
	presenter._layout_finished_stock([0, 1], -1)
	assert(pool[1].position.is_equal_approx(drop_point))


func _visible_box(sprite: Sprite2D) -> Rect2:
	var bounds := Rect2(sprite.texture.get_image().get_used_rect())
	var extent := Vector2(sprite.texture.get_size())
	return Rect2(sprite.position + (bounds.position - extent * 0.5) * sprite.scale, bounds.size * sprite.scale)


func _check(presenter: Node2D, texture_path: String, scale: Vector2) -> void:
	var sprite := Sprite2D.new()
	sprite.texture = load(texture_path)
	sprite.scale = scale
	var ground := Vector2(123.0, 456.0)
	sprite.position = presenter._grounded_sprite_position(sprite, ground)
	var bounds := sprite.texture.get_image().get_used_rect()
	var bottom := float(bounds.end.y) - sprite.texture.get_height() * 0.5
	var visible_bottom := sprite.position.y + bottom * absf(sprite.scale.y)
	assert(is_equal_approx(sprite.position.x, ground.x))
	assert(is_equal_approx(visible_bottom, ground.y))
	sprite.texture = null
	sprite.free()
