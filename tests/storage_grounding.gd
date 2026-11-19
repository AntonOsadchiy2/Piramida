extends SceneTree

const WorldPresenter = preload("res://scripts/presentation/world_presenter.gd")


func _init() -> void:
	var presenter := WorldPresenter.new()
	_check(presenter, "res://assets/sprites/stone.png", Vector2.ONE * 0.94 * 4.0)
	_check(presenter, "res://assets/sprites/brick.png", Vector2.ONE * 4.0)
	presenter.free()
	print("PASS: storage sprites rest on their visible bottom edge")
	quit()


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
