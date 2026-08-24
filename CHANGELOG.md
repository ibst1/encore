# Changelog

## 1.1.0 (2026-08-24)

- The play key (F12) also stops an ongoing recording.
- Name recordings, export a copy and load macro files from the tray menu.
- Smart replay: Alt+Tab sequences and taskbar switch clicks are replaced
  by their window anchors (the switcher never opens — playback jumps
  straight to the right window); anchors record the process path and
  start the program when it is not running; rapid clicks are fused into
  atomic double-clicks; moved/resized/maximized/minimized windows get
  corrective geometry anchors. Shell surfaces (the switcher, Task View,
  the taskbar, Start) can no longer become anchors.

## 1.0.0 (2026-08-24)

- Initial release: records keyboard, mouse (movements, clicks, wheel) and
  window switches; plays back at original speed (adjustable factor) or
  with a fixed pause between events; repeat 1-N times or until aborted,
  with a configurable pause between repetitions. Every recording is saved
  as a timestamped file and selectable from the tray menu. Window anchors
  re-activate the right program during playback. Default hotkeys:
  Shift+F12 record/stop, F12 play/abort.
