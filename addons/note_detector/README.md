# Godot Note Pitch Detector Addon ♪

Adds a `NoteDetector` node that emits signals when it detects musical notes from the microphone.

Useful for creating musical games, interactive toys, visualizers, etc.

![Inspector Screenshot](../../images/screenshot.png)

## Prerequisites

Enable the addon in the project settings:

`Project Settings > Addons > Note Pitch Detector > Enable`

You also need to enable audio input:

`Project Settings > Audio > Driver > Enable Audio Input`

Make sure to select the audio input device you want to use.
The addon selects the system default (device 0) by default.

```gdscript
# Get a list of available audio devices
# You can put this in a UI to allow device selection
var devices = AudioServer.get_input_device_list()

# Set the audio input device to the first device
AudioServer.input_device = devices[0] # Use the first device
```

## Usage

Place a `NoteDetector` node in your scene and connect the signals to your own logic.

```gdscript
@onready var note_detector = $NoteDetector

func _ready() -> void:
  note_detector.detect_note_started.connect(on_note_started)

func on_note_started(event: NoteDetectEvent) -> void:
  print("Note detected: ", event.note_name)
```

### NoteDetector Node
#### Properties
- `threshold`: The duration (in milliseconds) a note has to be sustained before the detection signal is emitted.
- `release`: The duration (in milliseconds) a note has to be released before the detection signal is emitted.
- `grace_period`: The duration (in milliseconds) a note can be "not detected" during buildup before the buildup is cancelled.
- `transpose`: The number of semitones to transpose the detected note.

#### Signals
- `detect_note_started(event: NoteDetectEvent)`: Emitted when a note is detected.
- `detect_note_stopped(event: NoteDetectEvent)`: Emitted when a note is no longer detected.
- `detect_started`: Emitted when the note detector starts detecting notes (after silence).
- `detect_stopped`: Emitted when the note detector stops detecting notes (silence).

#### NoteDetectEvent

- `note_name`: The name of the note (e.g. "C", "C#", "D", etc.).
- `note_full_name`: The full name of the note (e.g. "C#3", "D4", etc.).
- `note_index`: The index of the note (0 = C0, 1 = C#0, 12 = C1, etc.).
- `note_octave`: The octave of the note (0 = C0, 1 = C1, etc.).

### PitchDetectorServer

The `PitchDetectorServer` is an autoload that handles pitch detection in Hz. It is added to your project when you enable the addon.

The server uses autocorrelation by default for quick and simple detection. You can optionally use YIN, which might better for voice, wind instruments, etc.

```gdscript
PitchDetectorServer.algorithm = PitchDetectorServer.Algorithm.YIN
```

Read more: https://www.hyuncat.com/blog/yin/
