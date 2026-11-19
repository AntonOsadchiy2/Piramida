extends SceneTree

const Mixed = preload("res://tests/blueprint_large_blocks.gd")

func _initialize() -> void:
	quit(0 if Mixed.new().run() else 1)
