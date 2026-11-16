extends RefCounted
## Keeps the rendered sky independent of construction time and world resets.

const Astronomy := preload("res://scripts/presentation/giza_sky.gd")
const STAR_CATALOG := "res://assets/wallpaper/sky/bright-stars.txt"
const CLOCK_JUMP_SECONDS := 2.0
const CLOCK_BLEND_SECONDS := 4.0

class SkyFrame:
	var palette := Vector4.ZERO
	var sun := Vector2.ZERO
	var moon := Vector2.ZERO
	var lunar_light := Vector3.ZERO
	var stars := PackedVector3Array()
	var star_opacity := 0.0

var palette := Vector4.ZERO
var celestial: SkyFrame
var celestial_opacity := 1.0

var _catalog := PackedVector3Array()
var _last_utc := 0.0
var _last_tick := -1.0
var _sample_second := -1
var _start: SkyFrame
var _end: SkyFrame
var _blend_start := 0.0
var _outgoing: SkyFrame
var _outgoing_palette := Vector4.ZERO
var _outgoing_opacity := 1.0


func _init() -> void:
	for line in FileAccess.get_file_as_string(STAR_CATALOG).split("\n", false):
		if line.begins_with("#"):
			continue
		var fields := line.strip_edges().split(",")
		if fields.size() == 3:
			_catalog.append(Vector3(fields[0].to_float(), fields[1].to_float(), fields[2].to_float()))


func update(utc: float, tick: float) -> void:
	var elapsed := tick - _last_tick
	if _last_tick >= 0.0 and (elapsed >= CLOCK_JUMP_SECONDS
			or absf((utc - _last_utc) - elapsed) >= CLOCK_JUMP_SECONDS):
		_blend_start = tick
		_outgoing = celestial
		_outgoing_palette = palette
		_outgoing_opacity = celestial_opacity
	_last_utc = utc
	_last_tick = tick

	var second := floori(utc)
	if _start == null or second != _sample_second:
		_start = _end if _end != null and second == _sample_second + 1 else _sample(second)
		_end = _sample(second + 1)
		_sample_second = second

	var fraction := utc - second
	palette = _start.palette.lerp(_end.palette, fraction)
	celestial_opacity = 1.0
	if _outgoing != null:
		var progress := (tick - _blend_start) / CLOCK_BLEND_SECONDS
		palette = _outgoing_palette.lerp(palette, smoothstep(0.0, 1.0, progress))
		if progress < 0.5:
			celestial = _outgoing
			celestial_opacity = _outgoing_opacity * (1.0 - smoothstep(0.0, 0.5, progress))
			return
		celestial_opacity = smoothstep(0.5, 1.0, progress)
		if progress >= 1.0:
			_outgoing = null
	celestial = _interpolate(fraction)


func _sample(utc: float) -> SkyFrame:
	var frame := SkyFrame.new()
	var solar := Astronomy.sun(utc, Astronomy.TOMSK)
	var lunar := Astronomy.moon(utc, Astronomy.TOMSK)
	frame.palette = Astronomy.palette(solar)
	frame.sun = Astronomy.project(solar)
	frame.moon = Astronomy.project(lunar)
	frame.lunar_light = Astronomy.lunar_light(lunar, solar)
	frame.star_opacity = 1.0 - smoothstep(-18.0, -6.0, solar.y)
	if frame.star_opacity > 0.0:
		for coordinate in _catalog:
			var point := Astronomy.project(
				Astronomy.equatorial_to_horizontal(utc, coordinate.x, coordinate.y))
			frame.stars.append(Vector3(point.x, point.y, coordinate.z))
	return frame


func _interpolate(fraction: float) -> SkyFrame:
	var frame := SkyFrame.new()
	frame.sun = _interpolate_point(_start.sun, _end.sun, fraction)
	frame.moon = _interpolate_point(_start.moon, _end.moon, fraction)
	frame.lunar_light = _start.lunar_light.lerp(_end.lunar_light, fraction).normalized()
	frame.star_opacity = lerpf(_start.star_opacity, _end.star_opacity, fraction)
	if _start.stars.is_empty() or _end.stars.is_empty():
		frame.stars = _end.stars if _start.stars.is_empty() else _start.stars
	else:
		frame.stars.resize(_start.stars.size())
		for i in range(frame.stars.size()):
			var start := _start.stars[i]
			var end := _end.stars[i]
			frame.stars[i] = Vector3(_interpolate_azimuth(start.x, end.x, fraction),
				lerpf(start.y, end.y, fraction), start.z)
	return frame


static func _interpolate_point(start: Vector2, end: Vector2, fraction: float) -> Vector2:
	return Vector2(_interpolate_azimuth(start.x, end.x, fraction), lerpf(start.y, end.y, fraction))


static func _interpolate_azimuth(start: float, end: float, fraction: float) -> float:
	return fposmod(start + wrapf(end - start, -0.5, 0.5) * fraction, 1.0)
