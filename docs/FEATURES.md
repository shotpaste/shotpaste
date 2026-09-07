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
- The One Shot pre-recording panel also owns automatic transcription,
  AI processing and spoken-language choices. GIF and recordings without an audio
  source cannot enable transcription. A verified AI Transcription account is
  required. Starting remembers the choices and passes them with that recording;
  cancelling the panel does not save its draft options.
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
- On macOS, AI Features groups the LLM provider, AI Transcription, AI Translation
  and Agent Mode controls. Preferences contain configuration only; transcripts
  and task progress are shown in the independent Transcription Results window.
- Separate after-capture actions for screenshots and recordings: save, copy,
  and show Quick Access.
- Configurable One Shot, Clipboard History, and active-recording shortcuts.
- Expanded `shotpaste://` commands for capture modes, filtered history,
  settings, and recording controls.
- Authenticated local MCP Streamable HTTP tools for macOS agents; see
  [AUTOMATION.md](AUTOMATION.md).
- Appearance, language, diagnostics, startup, storage, output, recording, and
  history controls.
- macOS also maintains a local TOML preferences file; Windows stores settings
  in its local application-data directory.

## Audio recording

- Start audio recording from the menu bar/tray or an optional dedicated shortcut,
  without a One Shot selection on either platform.
  Start Audio Recording and Transcription Results are adjacent, with separators
  around their menu group.
- Choose system audio, microphone, or both. The control bar and history use
  audio-specific presentation; the history category groups video and audio.
- Windows uses native WASAPI loopback and microphone capture without a screen
  stream. Source-role PCM is retained in private recovery sessions until validated
  M4A and durable receipts exist; separate source M4As preserve system/microphone
  attribution during transcription. Pause, resume, restart, discard and stop are
  available from its audio control window and active-recording shortcuts.
- Stopping saves validated audio-only M4A. Disabling history is a deliberate
  opt-out, not a save failure, and never creates a synthetic history row.
  Temporary video deletion still requires validated audio and a durable task.
- Quitting during recording waits for audio saving; a failed save cancels quit.
  Transcription and organization run after capture has stopped and do
  not block screenshots. System capture permission and indicators still apply.
- Audio saving allows bounded audio/video duration differences from the private
  1 fps capture (up to 1.1 seconds for short recordings, capped at 20% before
  the existing duration tolerance). Manifest/container checks remain strict;
  clearly truncated audio remains recoverable instead of being silently accepted.
- A saved recording with failed transcription is labeled separately from capture
  failure. Retry retains the original audio and durable processing task.
  Processing status and retry are available in Transcription Results; the menu
  bar menu and icon tooltip do not show a separate post-processing status item.
- Transcription is opt-in and uses a speech API Key plus dedicated TOS
  AK/SK in AI Features → AI Transcription. Save only stores credentials locally;
  Save and test also configures private storage and verifies a paid public sample.
  Auto detects speech language;
  the ten UI languages are selectable. Only selected audio is sent, never frames.
  Apple Speech permission and local speech models are not required by this pipeline.
- Optional intelligent processing sends segment IDs and transcript text to the
  configured Agent LLM API (OpenAI-compatible or Anthropic Messages). Audio,
  media paths and video frames are excluded. Local validation checks citations;
  failed AI processing preserves the raw transcript for retry.

## Recording transcription

- Both platforms use file recognition 2.0 (`volc.seedasr.auc`), replacing CLASI. On
  macOS, the speech
  Key and dedicated TOS AK/SK are explicitly saved in variant-isolated local
  preferences, using the same storage approach as the LLM API key. Credentials
  are masked in the UI and excluded from TOML exports, task records and logs.
  The app does not access Keychain for transcription; credentials that were only
  stored there must be entered again. Model IDs and arbitrary upload endpoints
  are not user inputs. Blank credential fields retain saved values; repeated
  saves retain the verified account and automatic-processing opt-ins.
- Initialization creates private standard Beijing storage with 2-day expiration
  and incomplete-multipart cleanup scoped to the installation prefix. Advanced
  existing storage must use an application bucket/prefix and pass private ACL,
  standard class, region and unversioned checks. Other lifecycle rules are retained.
  AI Transcription preferences contain credentials, connection testing and
  advanced private-storage options. Automatic screen transcription, AI processing
  and language are configured in the pre-recording panel, with separate opt-ins
  after successful account testing.
- Temporary GET URLs expire after 24 hours and are sent only to the fixed speech
  service. URLs and credentials never enter task records or diagnostics.
- Local saving completes first. Short audio is submitted whole, with per-part
  caps of 4 hours and 256 MiB. Longer exports choose the quietest 100 ms in the
  30 seconds before the cap, reduce duration again if oversized, and preserve
  absolute offsets without overlapping audio. Speaker IDs are scoped to a part;
  source tracks retain their separate system/microphone meaning.
- Private durable jobs preserve the original request ID before submission,
  optional provider task ID, raw results and deletion status. Interrupted submits
  query the original ID; they are not automatically submitted again. Polling
  backs off with Retry-After and has a total query-attempt limit. Startup and
  periodic maintenance resume unfinished jobs and independently retry deletion.
  Parent recording receipts retain saved local media references and the complete
  timeline so restart can continue remaining long-file parts.
- Closing a result window keeps work running. Explicit cancellation stops new
  requests and cleans cloud copies, but cannot undo provider billing. Background
  query/cleanup recovery continues independently of Preferences. Cloud task lists
  and original JSON export are no longer exposed in Preferences.
- macOS has one independent Transcription Results window, available from the menu
  bar and history toolbar. Audio and screen recording tasks share
  a searchable list with type filters, dates and processing/failure states. Starting
  automatic transcription opens and selects that task; closing the window does
  not cancel it. History cards and their context menus link to the matching task.
- Raw text is persisted before cleanup and AI. Original transcripts, polished
  text and organized notes have separate tabs; Copy and Save operate on the
  selected artifact. Text exports preserve transcript timestamps and structured
  note source times. Generated artifacts survive window closure and relaunch and
  remain readable if source media is removed. Results are retained independently
  of clipboard-history retention, in the existing variant-isolated task stores.
- AI results for screen recordings are persisted alongside their raw transcripts.
  Failed processing preserves previously generated artifacts for inspection and
  retry from the existing raw text without new ASR.
  Pending deletion keeps the original profile credentials available. Removing
  the current credentials is blocked while its active jobs/deletions remain.
- Automatic screen transcription and AI are independent opt-ins. The validation
  button uploads only a short public sample and discloses usage charges. Prices
  are dated estimates; actual account bills determine charges.
- Windows exposes cloud credentials and text-model configuration in Recording
  settings. Credentials and per-recording account snapshots use DPAPI under the
  current Windows user. Blank credential fields retain saved values. Snapshots
  bind capture, retries and cloud cleanup to the original account; exports omit
  both plaintext and encrypted credentials. Saving unchanged credentials retains
  verification; testing again performs a new paid public-sample request.
- Windows provides a searchable Transcription Results browser with audio/video
  filters and links from history. Detail windows retain original text, timestamps,
  polished text and structured notes separately. OpenAI-compatible Chat,
  Anthropic Messages and Responses providers accept text and stable segment IDs;
  organized results must cite existing segments. AI batches checkpoint locally so
  retry does not need new ASR. General notes and interview Q&A templates are available.
- Windows long audio uses persisted, non-overlapping part ranges with absolute
  offsets and the same 4-hour/256-MiB limits. Quiet-boundary selection reduces
  sentence cuts without promising natural sentence boundaries. Startup and
  minute-based maintenance resume original request IDs and retry cloud deletion.
  A new billable submission after a terminal failure requires explicit confirmation.
- Windows audio and screen-recording receipts preserve the capture-time cloud
  choice through saving, quitting and crash recovery. A durable job acknowledges
  the receipt; repeated recovery reuses that job instead of creating a second
  submission. Closing result windows does not cancel work.
- Windows implementation and cross-compilation do not establish native desktop
  or hardware acceptance. Those checks remain required on a powered-on Windows
  machine before release.

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
- To obtain macOS system audio, ShotPaste may internally use a very small
  temporary screen media stream. Ultimately, only the audio selected by the
  user and derived content are retained; temporary video never enters history
  or the user directory and is deleted after audio saving completes. If saving
  fails, it remains only in a private recovery session and is never exposed as
  video. This boundary does not claim that pixels are never captured during
  this internal step.
