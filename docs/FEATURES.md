# Feature list

ShotPaste is a local-first desktop capture application with separate native
implementations for macOS and Windows. The two clients aim for the same product
workflow while using the APIs and conventions of each operating system.

## One Shot

- One global shortcut and tray/menu entry starts capture.
- The user selects one frozen screen region.
- The same region can be used for Screenshot, Scrolling, or Recording before a
  mode is committed.
- Clipboard opens Clipboard History without starting a capture.
- Capture windows and temporary state are restored or removed on cancel.

## Screenshot and annotation

- Adjustable region selection across the virtual desktop.
- Frozen selection surface with window targeting and magnification support.
- PNG, JPEG, and WebP screenshot output where supported.
- Configurable name templates, folder, scale, color space, cursor, desktop
  visibility, and notifications.
- Inline tools: select, rectangle, ellipse, line, arrow, text, highlighter,
  mosaic, spotlight, counter, pencil, and erasing/selection actions.
- Multi-selection, move, resize, property editing, undo, and redo.
- Local OCR, QR recognition, link detection, clipboard copy, and pinning.
- Fixed palettes and an intentionally reduced editor surface; there is no
  separate file-open annotation application.

## Scrolling capture

- Starts from the selected One Shot region.
- Manual and automatic scrolling.
- Live preview and incremental frame processing.
- Overlap matching, duplicate rejection, direction protection, fixed-edge
  handling, recovery matching, and final-tail sealing.
- Produces one long image and uses the normal screenshot output actions.

## Recording

- Records the selected One Shot region; there is no separate display/window
  recording entry.
- Video and GIF workflows.
- H.264 support on both platforms; additional format/codec options are exposed
  only when the native platform supports them.
- System audio and microphone controls, including independent volume settings.
- Cursor, click highlight, keystroke overlay, and non-selected-area dimming.
- Pause/resume, restart, discard, stop, snapshot, and live annotation controls.
- Temporary and recovery files are managed until the output is committed.

## Quick Access and pins

- Up to five recent post-capture cards.
- Configurable position, size, timeout, hover pause, animation, actions, and
  swipe behavior.
- Copy, save/open, dismiss, delete, and pin actions.
- Drag files into other applications.
- Always-on-top screenshot pins with zoom, opacity, lock/click-through, copy,
  save, and drag-out support.

## Clipboard History

- Local SQLite-backed history for screenshots, scrolling captures, recordings,
  GIFs, clipboard text, images, and copied files.
- Managed copies of clipboard files so history does not depend on the original
  path remaining available.
- Content hashing and deduplication.
- Filtering, search, compact/expanded layouts, multiple selection, copy, open,
  restore, and delete actions.
- Configurable retention and maximum item count.
- Transient and private clipboard formats are ignored.

## Preferences and automation

- General, capture, Quick Access, history, shortcuts, permissions, and advanced
  settings.
- Separate after-capture actions for screenshots and recordings: save, copy,
  and show Quick Access.
- Configurable One Shot, Clipboard History, and active-recording shortcuts.
- `shotpaste://` URL commands for One Shot, history, and settings.
- Appearance, language, diagnostics, startup, storage, output, recording, and
  history controls.
- macOS also maintains a local TOML preferences file; Windows stores settings
  in its local application-data directory.

## Languages

The interface supports English, Vietnamese, Simplified Chinese, Traditional
Chinese, Spanish, Japanese, Korean, Russian, French, and German. Some
Windows-only text uses English when a locale-specific translation is
unavailable.

## Privacy boundary

- Processing and storage are local to the device.
- ShotPaste has no project-operated account, telemetry, upload, cloud storage,
  or sync service.
- OCR and QR payloads are treated as text and are not executed automatically.
- Screen capture, microphone, accessibility/input, file, and startup permissions
  are requested only for features that need them.
