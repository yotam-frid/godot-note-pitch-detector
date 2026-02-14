class_name NoteDetectEvent
extends RefCounted

## Represents the name of the note, e.g "C#".
var note_name: String
## Represents the full name of the note, e.g "C#3".
var note_full_name: String
## Represents the [b]absolute index[/b] of the note. 0 = C0, 1 = C#0, 12 = C1, etc.
var note_index: int
## Represents the [b]octave[/b] of the note. Ranges from 0 to 8.
var note_octave: int

const _NOTE_NAMES: PackedStringArray = [
	"C", "C#", "D", "D#", "E", "F",
	"F#", "G", "G#", "A", "A#", "B",
]

static func create_from_index(note_index: int) -> NoteDetectEvent:
	var event: NoteDetectEvent = NoteDetectEvent.new()
	event.note_index = note_index
	event.note_name = _NOTE_NAMES[note_index % 12]
	event.note_octave = note_index / 12
	event.note_full_name = event.note_name + str(event.note_octave)
	return event
