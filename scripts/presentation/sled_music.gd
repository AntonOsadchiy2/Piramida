extends AudioStreamPlayer
## Microphone analysis for the visual jump of bricks on sleds.
## Spectrum sampling adapted from Godot's Audio Spectrum Visualizer Demo:
## https://github.com/godotengine/godot-demo-projects/tree/4.2-31d1c0c/audio/spectrum
## The muted bus follows the Audio Microphone Record Demo from the same repository.
##
## Copyright (c) 2014-present Godot Engine contributors.
## Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.
##
## Permission is hereby granted, free of charge, to any person obtaining
## a copy of this software and associated documentation files (the
## "Software"), to deal in the Software without restriction, including
## without limitation the rights to use, copy, modify, merge, publish,
## distribute, sublicense, and/or sell copies of the Software, and to
## permit persons to whom the Software is furnished to do so, subject to
## the following conditions:
##
## The above copyright notice and this permission notice shall be
## included in all copies or substantial portions of the Software.
##
## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
## EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
## MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
## IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
## CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
## TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
## SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

const INPUT_BUS := &"SledMicrophone"
const BASS_LOW_HZ := 45.0
const BASS_HIGH_HZ := 220.0
const MIN_DB := 60.0
const MIN_BASS_ENERGY := 0.20
const MIN_BASS_RISE := 0.08
const BASS_AVERAGE_SECONDS := 0.09
const JUMP_SECONDS := 0.30

var _spectrum: AudioEffectSpectrumAnalyzerInstance
var _bass_average := 0.0
var _jump_elapsed := JUMP_SECONDS
var _jump_peak := 0.0


func _ready() -> void:
	var input_bus := AudioServer.get_bus_index(INPUT_BUS)
	if input_bus < 0 or not AudioServer.is_bus_mute(input_bus):
		return
	_spectrum = AudioServer.get_bus_effect_instance(input_bus, 0) as AudioEffectSpectrumAnalyzerInstance
	if _spectrum == null:
		return
	bus = INPUT_BUS
	stream = AudioStreamMicrophone.new()
	play()


func jump_height(delta: float) -> float:
	if _spectrum == null:
		return 0.0
	var magnitude := _spectrum.get_magnitude_for_frequency_range(BASS_LOW_HZ, BASS_HIGH_HZ).length()
	var energy := clampf((MIN_DB + linear_to_db(magnitude)) / MIN_DB, 0.0, 1.0)
	var rise := energy - _bass_average
	_bass_average = lerpf(_bass_average, energy, 1.0 - exp(-delta / BASS_AVERAGE_SECONDS))
	_jump_elapsed = minf(_jump_elapsed + delta, JUMP_SECONDS)
	if _jump_elapsed == JUMP_SECONDS and energy >= MIN_BASS_ENERGY and rise >= MIN_BASS_RISE:
		_jump_elapsed = 0.0
		_jump_peak = lerpf(20.0, 70.0, energy)
	var phase := _jump_elapsed / JUMP_SECONDS
	return _jump_peak * 4.0 * phase * (1.0 - phase)
