extends Node2D

const CLOUD_SHADER := preload("res://scripts/presentation/cloud_day_night.gdshader")
const SKY_ASSETS := "res://assets/wallpaper/sky/"
const TALL := "01_tall_cumulus"
const WIDE := "02_wide_cumulus"
const TOWERING := "03_towering_cumulus"
const CIRRUS := "04_wispy_cirrus"
const BROKEN := "05_broken_cumulus"
const CLOUD_FORMS := [CIRRUS, WIDE, BROKEN, BROKEN, TOWERING, TALL, CIRRUS, TALL, WIDE]
const BAND_HEIGHTS := [0.19, 0.45, 0.73]
const BAND_WIDTHS := [0.54, 0.68, 0.77]
const BAND_SIZE_MULTIPLIERS := [0.75, 0.45, 0.30]
const BAND_SPEEDS := [0.009, 0.014, 0.019]
const BAND_PHASE_OFFSETS := [0.0, 0.29, 0.53]
const CLOUDS_PER_BAND := 3
const CLOUD_SIZE_MULTIPLIERS := [1.0, 0.75, 0.5]

var _sprites: Array[Sprite2D] = []
var _materials: Dictionary[String, ShaderMaterial] = {}
var _aspect_ratios: Dictionary[String, float] = {}
var _phases := PackedFloat64Array()
var _offsets := PackedVector2Array()
var _width_factors := PackedFloat32Array()
var _band_widths := PackedFloat32Array()
var _sky_area: Rect2


func _ready() -> void:
	var phase := randf()
	for band in range(BAND_HEIGHTS.size()):
		_phases.append(phase + BAND_PHASE_OFFSETS[band])
		_band_widths.append(0.0)

	for index in range(CLOUD_FORMS.size()):
		var form: String = CLOUD_FORMS[index]
		var sprite := Sprite2D.new()
		sprite.texture = load(SKY_ASSETS + "cloud_" + form + ".png")
		sprite.material = _material_for(form, sprite.texture)
		sprite.hide()
		add_child(sprite)
		_sprites.append(sprite)
		var band_count := BAND_HEIGHTS.size()
		var slot := floori(float(index) / band_count)
		_offsets.append(Vector2(float(slot) / CLOUDS_PER_BAND + randf_range(-0.045, 0.045),
			randf_range(-0.035, 0.035)))
		# Stagger sizes so each band and the sparse cloud cover show a mix.
		var size_index := (slot + index % band_count) % CLOUD_SIZE_MULTIPLIERS.size()
		_width_factors.append(randf_range(0.80, 1.0) * CLOUD_SIZE_MULTIPLIERS[size_index])


func set_daylight(palette: Vector4) -> void:
	var tint_top := Color("#1c2048") * palette.x + Color("#5372a3") * palette.y \
		+ Color("#5b98cc") * palette.z + Color("#343267") * palette.w
	var tint_bottom := Color("#504078") * palette.x + Color("#deb4b1") * palette.y \
		+ Color("#aedce9") * palette.z + Color("#c87c9c") * palette.w
	for material in _materials.values():
		material.set_shader_parameter("sky_tint_top", tint_top)
		material.set_shader_parameter("sky_tint_bottom", tint_bottom)
		material.set_shader_parameter("night_mix", palette.x)


func _material_for(form: String, day: Texture2D) -> ShaderMaterial:
	if not _materials.has(form):
		var night: Texture2D = load(SKY_ASSETS + "cloud_night_" + form + ".png")
		var day_aspect := float(day.get_height()) / day.get_width()
		var night_aspect := float(night.get_height()) / night.get_width()
		var aspect := maxf(day_aspect, night_aspect)
		var material := ShaderMaterial.new()
		material.shader = CLOUD_SHADER
		material.set_shader_parameter("night_texture", night)
		material.set_shader_parameter("relative_heights", Vector2(day_aspect, night_aspect) / aspect)
		_materials[form] = material
		_aspect_ratios[form] = aspect
	return _materials[form]


func update_clouds(delta: float, sky_area: Rect2, cover: float) -> void:
	if not sky_area.has_area():
		return
	if sky_area != _sky_area:
		_layout(sky_area)
	for band in range(BAND_HEIGHTS.size()):
		var track_width := _sky_area.size.x + _band_widths[band]
		var distance: float = BAND_SPEEDS[band] * _sky_area.size.y * delta
		_phases[band] = fposmod(_phases[band] + distance / track_width, 1.0)
	for index in range(_sprites.size()):
		var sprite := _sprites[index]
		var threshold := 0.8 * float(index) / (_sprites.size() - 1)
		var opacity := smoothstep(threshold, threshold + 0.2, cover)
		sprite.visible = opacity > 0.0
		sprite.self_modulate.a = opacity
		var band := index % BAND_HEIGHTS.size()
		var margin := _band_widths[band] * 0.5
		var track_position := fposmod(_phases[band] + _offsets[index].x, 1.0)
		sprite.position.x = _sky_area.position.x - margin \
			+ track_position * (_sky_area.size.x + 2.0 * margin)


func _layout(sky_area: Rect2) -> void:
	_sky_area = sky_area
	for band in range(BAND_HEIGHTS.size()):
		_band_widths[band] = minf(sky_area.size.y * BAND_WIDTHS[band], sky_area.size.x * 0.45)
	for index in range(_sprites.size()):
		var sprite := _sprites[index]
		var band := index % BAND_HEIGHTS.size()
		var width: float = _band_widths[band] * _width_factors[index] * BAND_SIZE_MULTIPLIERS[band]
		var aspect := _aspect_ratios[CLOUD_FORMS[index]]
		sprite.scale = Vector2(width, width * aspect) / sprite.texture.get_size()
		var height: float = BAND_HEIGHTS[band] + _offsets[index].y
		sprite.position.y = sky_area.position.y + height * sky_area.size.y
