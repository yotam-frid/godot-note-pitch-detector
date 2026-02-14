@icon("music_note.svg")
class_name NoteDetector
extends Node

signal detect_note_started(event: NoteDetectEvent)
signal detect_note_stopped(event: NoteDetectEvent)
signal detect_started
signal detect_stopped

## The duration (in milliseconds) a note has to be sustained before the detection signal is emitted.
@export var threshold: float = 40.0
## The duration (in milliseconds) a note has to be released before the detection signal is emitted.
@export var release: float = 50.0
## The duration (in milliseconds) a note can be "not detected" during buildup before the buildup is cancelled.
## Allows the pitch detector to flicker for a frame or two without resetting buildup progress.
@export var grace_period: float = 30.0

## The number of semitones to transpose the detected note.
@export var transpose: int = 0

var detected_volume: float = 0.0

## The number of cents the detected pitch is off from the current played/detected note (-50 to +50).
var cents_offset: float:
	get:
		if _pitch_provider == null:
			return 0.0
		var freq: float = _pitch_provider.current_frequency
		if freq <= 0.0:
			return 0.0
		var ref_index: int = _sustained_note_index
		if ref_index < 0:
			ref_index = clampi(_frequency_to_index(freq) + transpose, 0, NOTE_COUNT - 1)
		var ref_freq: float = C0_HZ * pow(2.0, ref_index / 12.0)
		return 1200.0 * log(freq / ref_freq) / log(2.0)


enum NoteState {IDLE, BUILDING_UP, PLAYING, RELEASING}

var _pitch_provider: Node = null
var _note_states: PackedInt32Array # NoteState per note
var _elapsed: PackedFloat32Array # threshold or release elapsed ms per note
var _grace_elapsed: PackedFloat32Array # grace period tracker during buildup
var _sustained_note_index: int = -1 # The note we're currently sustaining (PLAYING or RELEASING)

var is_playing: bool = false

const NOTE_COUNT: int = 12 * 9 # 12 notes per octave, 9 octaves
const C0_HZ: float = 16.35 # C0 = index 0

func _init() -> void:
	_note_states.resize(NOTE_COUNT)
	_elapsed.resize(NOTE_COUNT)
	_grace_elapsed.resize(NOTE_COUNT)
	for i in NOTE_COUNT:
		_note_states[i] = NoteState.IDLE
		_elapsed[i] = 0.0
		_grace_elapsed[i] = 0.0


func _enter_tree() -> void:
	_pitch_provider = get_node_or_null("/root/PitchDetectorServer")
	if _pitch_provider == null:
		push_error("NoteDetector: PitchDetectorServer autoload not found. Is the addon enabled?")
		return
	_pitch_provider.request_listening()


func _exit_tree() -> void:
	if _pitch_provider != null:
		_pitch_provider.release_listening()
		_pitch_provider = null


func _process(delta: float) -> void:
	if _pitch_provider == null:
		return

	var raw_index: int = _frequency_to_index(_pitch_provider.current_frequency)
	var delta_ms: float = delta * 1000.0

	detected_volume = _pitch_provider.current_energy

	var current_index: int = -1
	if raw_index >= 0:
		current_index = clampi(raw_index + transpose, 0, NOTE_COUNT - 1)

	is_playing = false
	var released_note_this_frame: bool = false

	for i in NOTE_COUNT:
		var state: int = _note_states[i]
		var elapsed: float = _elapsed[i]
		var is_current: bool = (i == current_index)

		if is_current:
			match state:
				NoteState.IDLE:
					_note_states[i] = NoteState.BUILDING_UP
					_elapsed[i] = delta_ms
					_grace_elapsed[i] = 0.0
				NoteState.BUILDING_UP:
					_grace_elapsed[i] = 0.0
					elapsed += delta_ms
					_elapsed[i] = elapsed
					if elapsed >= threshold:
						var was_switching := _sustained_note_index >= 0 and _sustained_note_index != i
						# Emit stopped for the previous sustained note before starting the new one
						if was_switching:
							detect_note_stopped.emit(NoteDetectEvent.create_from_index(_sustained_note_index))
							_note_states[_sustained_note_index] = NoteState.IDLE
							_elapsed[_sustained_note_index] = 0.0
							_sustained_note_index = -1
						_note_states[i] = NoteState.PLAYING
						_elapsed[i] = 0.0
						if not was_switching:
							detect_started.emit()
						detect_note_started.emit(NoteDetectEvent.create_from_index(i))
						_sustained_note_index = i
				NoteState.PLAYING:
					is_playing = true
					_elapsed[i] = 0.0
				NoteState.RELEASING:
					_note_states[i] = NoteState.PLAYING
					_elapsed[i] = 0.0
					is_playing = true
		else:
			match state:
				NoteState.BUILDING_UP:
					_grace_elapsed[i] += delta_ms
					if _grace_elapsed[i] >= grace_period:
						_note_states[i] = NoteState.IDLE
						_elapsed[i] = 0.0
						_grace_elapsed[i] = 0.0
				NoteState.PLAYING:
					_note_states[i] = NoteState.RELEASING
					_elapsed[i] = delta_ms
				NoteState.RELEASING:
					elapsed += delta_ms
					_elapsed[i] = elapsed
					if elapsed >= release:
						_note_states[i] = NoteState.IDLE
						_elapsed[i] = 0.0
						if _sustained_note_index == i:
							_sustained_note_index = -1
						detect_note_stopped.emit(NoteDetectEvent.create_from_index(i))
						released_note_this_frame = true
				NoteState.IDLE:
					pass

	if released_note_this_frame and _sustained_note_index < 0:
		detect_stopped.emit()


## Returns semitone index with C0 = 0. -1 when no pitch.
static func _frequency_to_index(frequency: float) -> int:
	if frequency <= 0.0 or frequency < C0_HZ:
		return -1
	# Semitones from C0. C0 = index 0, C1 = 12, A4 = 57, etc.
	var semitones_from_c0 := 12.0 * log(frequency / C0_HZ) / log(2.0)
	return maxi(0, int(roundf(semitones_from_c0)))
