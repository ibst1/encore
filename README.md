# Encore

A Windows macro recorder in the system tray: record what you do — keystrokes, mouse movements, clicks, scrolling and window switches — and play it back. *Encore!*

- **Shift+F12** starts recording; the same key stops it. **F12** plays the selected recording; F12 again — or **Esc** — aborts. Both hotkeys are configurable.
- **Playback modes**: original timing (with an adjustable speed factor) or a fixed pause between events.
- **Repeat**: play 1–N times or until aborted, with a configurable pause between repetitions (tray menu → *Repeat*).
- **Every recording is kept**: each one is saved as a timestamped file in `macros\` and selectable from the tray menu (*Recordings*). Rename or delete the files to manage them; the file name is the menu name.
- **Window anchors**: at the start of a recording and at every window switch, Encore records *which program* was active. During playback it re-activates that program (matched by process name, with title-substring fallback) and waits until it is active — so switching to Excel mid-recording reliably switches to Excel mid-playback, even if a replayed Alt+Tab would have landed elsewhere.
- The tray icon shows the state: blue square = idle, red dot = recording, green triangle = playing.

## Installation

### Option A — portable exe (no AutoHotkey required)

1. Download the latest `Encore-x.y.z.zip` from [Releases](https://github.com/ibst1/encore/releases) and extract it anywhere.
2. Run `Encore.exe`.

`Encore.exe` is the unmodified official AutoHotkey v2 interpreter, renamed — when started it loads the `Encore.ahk` script beside it. All application code ships as readable text, and the binary is byte-identical to the official AutoHotkey release (which also keeps antivirus false positives away).

### Option B — run the script

1. Windows with [AutoHotkey v2](https://www.autohotkey.com/) installed.
2. Run `Encore.ahk`.

## Configuration

`Encore config.ini` is created next to the script on first start (UTF-16 — keep that encoding). Edit it via the tray menu (*Open configuration*) and reload with *Reload configuration*.

| Key | Default | Meaning |
|---|---|---|
| `RecordHotkey` | `+F12` | Starts/stops recording. AutoHotkey syntax: `+` Shift, `^` Ctrl, `#` Win, `!` Alt. Empty disables |
| `PlayHotkey` | `F12` | Plays the selected recording; during playback it aborts |
| `Mode` | `original` | `original` (recorded timing) or `fixed` (fixed pause between events) |
| `Speed` | `1.0` | Playback speed factor in original mode — `2` = twice as fast |
| `FixedDelayMs` | `50` | The pause between events in fixed mode |
| `MaxWaitMs` | `5000` | Longest single pause replayed in original mode |
| `MousePollMs` | `15` | Mouse sampling interval while recording |
| `MaxEvents` | `100000` | Safety cap on the number of recorded events |
| `WindowAnchors` | `1` | Record and replay "switch to program X" anchors |
| `Repeat` | `1` | Playback repetitions; `0` = until aborted |
| `RepeatPauseMs` | `1000` | Pause between repetitions |

## Notes

- Recording deliberately uses AutoHotkey's native input mechanisms (InputHook, polling, pass-through hotkeys) instead of custom low-level hooks — Windows silently kills slow script hooks mid-recording, while the native path cannot be killed.
- Replayed input is sent at `SendLevel 1`, so other AutoHotkey scripts (hotstring expanders and similar) react to it like real typing.
- The macro files are plain tab-separated text: `k` lines are keys, `m` lines mouse events, `w` lines window anchors (`w <tab> 0 <tab> program.exe <tab> title part`) — editable by hand.
- Mouse presses shorter than `MousePollMs` can be missed; physical clicks last 50–150 ms, so the default 15 ms leaves ample margin.
- Other programs can control Encore by posting the registered window message `ENCORE_CMD` to its hidden window: wParam `1` = toggle recording, `2` = play, `3` = abort playback, `4` = reload the configuration.
