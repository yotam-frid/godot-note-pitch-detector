extends Node

## The current detected frequency in Hz. 0.0 when no pitch detected.
var current_frequency: float = 0.0

## RMS energy of the current audio buffer (~0.0 to 1.0). A linear measure of loudness.
var current_energy: float = 0.0

## Energy in decibels. Ranges from -80 (silence) to 0 (max).
var current_db: float = -80.0

## Confidence of the current pitch estimate (0.0 to 1.0). Higher is more reliable.
var current_confidence: float = 0.0

## Whether the server is currently capturing microphone audio.
var is_listening: bool = false

const BUFFER_SIZE: int = 2048
const AUDIO_BUS_NAME: StringName = &"PitchDetectorCapture"
const MIN_FREQ: float = 40.0 # Low E on bass ~41 Hz (or E2)
const MAX_FREQ: float = 700.0 # High E on guitar ~660 Hz (or E6)
const SILENCE_THRESHOLD: float = 0.005 # RMS below this is treated as silence
const DOWNSAMPLE_FACTOR: int = 4
const YIN_THRESHOLD: float = 0.15 # CMND threshold (lower = stricter)
const PARABOLIC_EPSILON: float = 1e-12

enum Algorithm {AUTOCORRELATION, YIN}

## Which pitch detection algorithm to use. Autocorrelation is faster; YIN rejects noise better.
@export var algorithm: Algorithm = Algorithm.AUTOCORRELATION

var _capture: AudioEffectCapture
var _mic_player: AudioStreamPlayer
var _listener_count: int = 0

# Precomputed constants for the valid lag range.
var _min_lag: int
var _max_lag: int


func _get_effective_sample_rate() -> float:
	return AudioServer.get_mix_rate() / float(DOWNSAMPLE_FACTOR)


func _apply_pitch_result(frequency: float) -> void:
	current_frequency = frequency


func _ready() -> void:
	var ds_size := BUFFER_SIZE / DOWNSAMPLE_FACTOR
	var sample_rate := _get_effective_sample_rate()
	_min_lag = int(sample_rate / MAX_FREQ)
	_max_lag = mini(int(sample_rate / MIN_FREQ), ds_size / 2 - 2)
	
	Performance.add_custom_monitor("Note Detector/Detect DB", func(): return current_db)
	Performance.add_custom_monitor("Note Detector/Detect Frequency", func(): return current_frequency)
	Performance.add_custom_monitor("Note Detector/Detect Confidence", func(): return current_confidence)
	_select_first_available_device()


## Call this when a listener (e.g. NoteDetector) wants pitch data.
## The microphone starts capturing when the first listener registers.
func request_listening() -> void:
	_listener_count += 1
	if _listener_count == 1:
		_start_capture()


## Call this when a listener no longer needs pitch data.
## The microphone stops when the last listener unregisters.
func release_listening() -> void:
	_listener_count -= 1
	if _listener_count <= 0:
		_listener_count = 0
		_stop_capture()


## Creates the capture bus with an AudioEffectCapture effect and mutes it.
func _create_capture_bus() -> int:
	AudioServer.add_bus()
	var bus_index := AudioServer.bus_count - 1
	AudioServer.set_bus_name(bus_index, AUDIO_BUS_NAME)
	AudioServer.add_bus_effect(bus_index, AudioEffectCapture.new(), 0)
	AudioServer.set_bus_mute(bus_index, true)
	return bus_index


func _start_capture() -> void:
	if _mic_player != null:
		return # Already capturing.

	var bus_index := AudioServer.get_bus_index(AUDIO_BUS_NAME)
	if bus_index == -1:
		# Create bus, add Capture effect, and mute it.
		bus_index = _create_capture_bus()
		if bus_index == -1:
			return

	# Ensure the bus is muted (idempotent if we just created it).
	AudioServer.set_bus_mute(bus_index, true)

	# Route microphone audio into the capture bus.
	_mic_player = AudioStreamPlayer.new()
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = AUDIO_BUS_NAME
	add_child(_mic_player)
	_mic_player.play()

	# Grab the Capture effect on the bus (we add it in _create_capture_bus when creating the bus).
	_capture = AudioServer.get_bus_effect(bus_index, 0) as AudioEffectCapture
	if _capture == null:
		push_error("PitchDetectorServer: First effect on bus '%s' is not AudioEffectCapture." % AUDIO_BUS_NAME)
		_mic_player.stop()
		_mic_player.queue_free()
		_mic_player = null
		return

	is_listening = true


func _stop_capture() -> void:
	if _mic_player != null:
		_mic_player.stop()
		_mic_player.queue_free()
		_mic_player = null
	_capture = null
	is_listening = false
	_set_no_pitch()
	current_energy = 0.0
	current_db = -80.0


func _exit_tree() -> void:
	_stop_capture()


func _process(_delta: float) -> void:
	if _capture == null or _mic_player == null:
		return

	var available := _capture.get_frames_available()
	if available < BUFFER_SIZE:
		return

	# Discard stale audio so we always analyse the most recent samples.
	var excess := available - BUFFER_SIZE
	if excess > 0:
		_capture.get_buffer(excess) # read & throw away old frames

	var buffer := _capture.get_buffer(BUFFER_SIZE)
	if buffer.is_empty():
		return

	# --- Convert stereo to mono ---
	var samples := PackedFloat32Array()
	samples.resize(BUFFER_SIZE)
	for i in BUFFER_SIZE:
		samples[i] = (buffer[i].x + buffer[i].y) * 0.5

	# --- Compute RMS energy ---
	var energy_sum := 0.0
	for i in BUFFER_SIZE:
		energy_sum += samples[i] * samples[i]
	var rms := sqrt(energy_sum / float(BUFFER_SIZE))
	current_energy = rms
	current_db = 20.0 * log(maxf(rms, 1e-10)) / log(10.0)

	if rms < SILENCE_THRESHOLD:
		_set_no_pitch()
		return

	# --- Downsample (box filter) for cheaper pitch detection ---
	var ds_size := BUFFER_SIZE / DOWNSAMPLE_FACTOR
	var ds_samples := PackedFloat32Array()
	ds_samples.resize(ds_size)
	for i in ds_size:
		var acc := 0.0
		var base := i * DOWNSAMPLE_FACTOR
		for j in DOWNSAMPLE_FACTOR:
			acc += samples[base + j]
		ds_samples[i] = acc / float(DOWNSAMPLE_FACTOR)

	# --- Pitch detection ---
	match algorithm:
		Algorithm.AUTOCORRELATION:
			_detect_pitch_autocorrelation(ds_samples)
		Algorithm.YIN:
			_detect_pitch_yin(ds_samples)


## Autocorrelation pitch detection (default). Fast; may pick up harmonics.
func _detect_pitch_autocorrelation(samples: PackedFloat32Array) -> void:
	var size := samples.size()
	var sample_rate := _get_effective_sample_rate()

	var energy := 0.0
	for i in size:
		energy += samples[i] * samples[i]

	if energy <= 0.0:
		_set_no_pitch()
		return

	var best_lag := -1
	var best_value := 0.0

	var prev_prev := _autocorrelation_at(samples, _min_lag - 1, size) / energy
	var prev := _autocorrelation_at(samples, _min_lag, size) / energy

	for lag in range(_min_lag + 1, _max_lag + 1):
		var cur := _autocorrelation_at(samples, lag, size) / energy

		if prev > best_value and prev > prev_prev and prev > cur:
			best_value = prev
			best_lag = lag - 1

		prev_prev = prev
		prev = cur

	if best_lag < 0:
		_set_no_pitch()
		return

	current_confidence = best_value

	var refined_lag := float(best_lag)
	if best_lag > 0:
		var y0 := _autocorrelation_at(samples, best_lag - 1, size) / energy
		var y1 := _autocorrelation_at(samples, best_lag, size) / energy
		var y2 := _autocorrelation_at(samples, best_lag + 1, size) / energy
		var denom := y0 - 2.0 * y1 + y2
		if abs(denom) > PARABOLIC_EPSILON:
			refined_lag += 0.5 * (y0 - y2) / denom

	_apply_pitch_result(sample_rate / refined_lag)


## Compute the (un-normalised) autocorrelation at a single lag value.
func _autocorrelation_at(samples: PackedFloat32Array, lag: int, size: int) -> float:
	var sum := 0.0
	var count := size - lag
	for i in count:
		sum += samples[i] * samples[i + lag]
	return sum


## YIN pitch detection. Uses CMND to find the fundamental period; rejects harmonics.
## [br]
## https://www.hyuncat.com/blog/yin/
func _detect_pitch_yin(samples: PackedFloat32Array) -> void:
	var size := samples.size()
	var sample_rate := _get_effective_sample_rate()
	var W := size / 2
	var upper := mini(_max_lag + 2, W)

	var cmnd := PackedFloat32Array()
	cmnd.resize(upper)
	cmnd[0] = 1.0

	var running_sum := 0.0
	for tau in range(1, upper):
		var diff := 0.0
		for j in W:
			var delta := samples[j] - samples[j + tau]
			diff += delta * delta
		running_sum += diff
		cmnd[tau] = diff * float(tau) / running_sum if running_sum > 0.0 else 1.0

	var best_tau := -1
	var tau := _min_lag

	while tau < upper:
		if cmnd[tau] < YIN_THRESHOLD:
			while tau + 1 < upper and cmnd[tau + 1] < cmnd[tau]:
				tau += 1
			best_tau = tau
			break
		tau += 1

	if best_tau < 0:
		_set_no_pitch()
		return

	current_confidence = 1.0 - cmnd[best_tau]

	var refined_tau := float(best_tau)
	if best_tau > 0 and best_tau < upper - 1:
		var y0 := cmnd[best_tau - 1]
		var y1 := cmnd[best_tau]
		var y2 := cmnd[best_tau + 1]
		var denom := y0 - 2.0 * y1 + y2
		if abs(denom) > PARABOLIC_EPSILON:
			refined_tau += 0.5 * (y0 - y2) / denom

	_apply_pitch_result(sample_rate / refined_tau)


func _set_no_pitch() -> void:
	current_frequency = 0.0
	current_confidence = 0.0

func _select_first_available_device() -> void:
	var devices := AudioServer.get_input_device_list()
	if devices.is_empty():
		push_error("PitchDetectorServer: No audio input devices available.")
		return

	AudioServer.input_device = devices[0]