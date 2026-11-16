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
		var next := _random.randi_range(1, Condition.size() - 1)
		condition = ((int(condition) + next) % Condition.size()) as Condition
		_duration = TRANSITION_SECONDS + _random.randf_range(STABLE_SECONDS.x, STABLE_SECONDS.y)
	var blend := smoothstep(0.0, TRANSITION_SECONDS, _elapsed)
	cloud_cover = lerpf(_previous_cover, CLOUD_COVER[condition], blend)
