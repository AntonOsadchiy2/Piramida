extends Node

const State = preload("res://scripts/domain/game_state.gd")

const MINE := preload("res://assets/audio/sfx_mine_hit.wav")
const DRESSER := preload("res://assets/audio/sfx_dresser_hit.wav")
const BRICK := preload("res://assets/audio/sfx_brick_place.wav")
const UPGRADE := preload("res://assets/audio/sfx_upgrade.wav")
const TRANSPORT := preload("res://assets/audio/sfx_transport_creak.wav")

var _priority := 0
var _next_impact_msec := 0
var _transport_level := 0.0

@onready var _impact := AudioStreamPlayer.new()
@onready var _upgrade := AudioStreamPlayer.new()
@onready var _transport := AudioStreamPlayer.new()


func _ready() -> void:
	for player in [_impact, _upgrade, _transport]:
		player.bus = &"SFX"
		add_child(player)
	_impact.volume_db = -6.0
	_upgrade.volume_db = -7.0
	_upgrade.stream = UPGRADE
	_transport.stream = TRANSPORT


func play_upgrade() -> void:
	_upgrade.play()


func play_production(events: Array[Dictionary]) -> void:
	var stream: AudioStreamWAV
	var priority := 0
	for event in events:
		match event.state:
			&"place_brick":
				stream = BRICK
				priority = 3
				break
			&"process_brick":
				stream = DRESSER
				priority = 2
			&"mine":
				if priority == 0:
					stream = MINE
					priority = 1
	if stream == null:
		return
	var now := Time.get_ticks_msec()
	if now < _next_impact_msec and priority <= _priority:
		return
	_priority = priority
	_next_impact_msec = now + 280
	_impact.stream = stream
	_impact.play()


func update_transport(state: State, active: bool, delta: float) -> void:
	var moving := false
	if active:
		for id in state.worker_ids():
			var phase := state.worker(id).fsm_state
			var loaded_pickup := phase == &"walk_to_pickup" and state.stock_count(id) > 0
			if loaded_pickup or phase == &"walk_to_storage" or phase == &"lift_brick":
				moving = true
				break

	_transport_level = move_toward(_transport_level, 1.0 if moving else 0.0, delta * 8.0)
	if _transport_level == 0.0:
		if _transport.playing:
			_transport.stop()
		return
	_transport.volume_db = -13.0 + linear_to_db(_transport_level)
	if not _transport.playing:
		_transport.play()
