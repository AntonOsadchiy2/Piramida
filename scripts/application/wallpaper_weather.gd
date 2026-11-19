extends RefCounted
## Procedural weather for the wallpaper, driven by elapsed display time.

enum Condition { CLEAR, PARTLY_CLOUDY, MOSTLY_CLOUDY }

const TRANSITION_SECONDS := 24.0
const STABLE_SECONDS := Vector2(100.0, 200.0)
const CLOUD_COVER := {
	Condition.CLEAR: 0.0,
	Condition.PARTLY_CLOUDY: 0.26,
	Condition.MOSTLY_CLOUDY: 1.0,
}

var condition: Condition
var cloud_cover: float
var _random := RandomNumberGenerator.new()
var _previous_cover: float
var _elapsed := 0.0
var _duration: float
var _stable := STABLE_SECONDS
var _transition := TRANSITION_SECONDS
var _weights := PackedFloat64Array([1.0, 1.0, 1.0])
var _configured := false


func configure(settings: Dictionary) -> void:
	_stable = Vector2(settings.weatherMin, settings.weatherMax)
	_transition = settings.weatherTransition
	_weights = PackedFloat64Array([settings.clearWeight, settings.partlyWeight, settings.cloudyWeight])
	_configured = true
	condition = _weighted_condition(-1)
	cloud_cover = CLOUD_COVER[condition]
	_previous_cover = cloud_cover
	_elapsed = 0.0
	_duration = _random.randf_range(_stable.x, _stable.y)


func _weighted_condition(exclude: int) -> Condition:
	var total := 0.0
	for i in range(_weights.size()):
		if i != exclude:
			total += _weights[i]
	if total <= 0.0:
		return exclude as Condition
	var pick := _random.randf() * total
	for i in range(_weights.size()):
		if i != exclude:
			pick -= _weights[i]
			if pick < 0.0:
				return i as Condition
	return exclude as Condition


func _init() -> void:
	condition = _random.randi_range(0, Condition.size() - 1) as Condition
	cloud_cover = CLOUD_COVER[condition]
	_previous_cover = cloud_cover
	_duration = _random.randf_range(STABLE_SECONDS.x, STABLE_SECONDS.y)


func advance(delta: float) -> void:
	_elapsed += delta
	while _elapsed >= _duration:
		_elapsed -= _duration
		_previous_cover = CLOUD_COVER[condition]
		if _configured:
			condition = _weighted_condition(int(condition))
		else:
			var next := _random.randi_range(1, Condition.size() - 1)
			condition = ((int(condition) + next) % Condition.size()) as Condition
		_duration = _transition + _random.randf_range(_stable.x, _stable.y)
	var blend := smoothstep(0.0, _transition, _elapsed)
	cloud_cover = lerpf(_previous_cover, CLOUD_COVER[condition], blend)
