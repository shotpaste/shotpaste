# Audio recording and transcription

[简体中文](RECORDING_TRANSCRIPTION.md) · **English**

This guide describes the current source branch. Availability in a downloaded
release depends on the platform version. See [FEATURES.md](FEATURES.md) for the
full behavior contract and [DEVELOPMENT.md](DEVELOPMENT.md) for native validation.

## Record locally

1. Choose **Start Audio Recording** from the macOS menu bar or Windows tray.
   An optional audio-recording shortcut can be assigned in shortcut settings.
2. Select system audio, microphone, or both in the preparation window. At least
   one source is required. Leave transcription off to record without cloud services.
3. Start recording. Use the audio controls to pause/resume, restart, discard,
   or stop. Stopping saves an audio-only M4A; a transcription failure does not
   mean that the saved recording failed.
4. Use the configured recording output actions and Quick Access to access the
   saved audio. When history is enabled, audio appears with recordings in history.
   Turning history off does not prevent audio saving.

Screen recording still starts from **One Shot → Recording** after selecting a
region. Its preparation panel holds the transcription, AI, and spoken-language
choices for that recording. GIF and recordings with neither audio source cannot
use transcription. Starting remembers the choices; cancelling preparation does
not save draft choices.

macOS audio recording internally uses a private 32 × 32 physical-pixel, 1 fps
screen stream. Screen Recording permission and system indicators still apply;
Microphone permission is needed when that source is selected. Temporary video
is retained only for recovery until validated audio and durable processing state
have been saved. It is never delivered as a video or entered into history.
Windows uses WASAPI for audio-only recording without a screen stream. The
transcription pipeline does not require Apple Speech permission or local models.

## Configure optional cloud transcription

| Setting | macOS | Windows |
| --- | --- | --- |
| Speech and storage credentials | AI Features → AI Transcription | Recording settings |
| Text model for optional AI processing | AI Features / Agent LLM configuration | Recording settings text-model configuration |
| Per-recording consent and language | Audio preparation or One Shot recording panel | Audio preparation or One Shot recording panel |
| Saved tasks and artifacts | Transcription Results | Transcription Results |

Use your own Volcengine speech API Key and a dedicated TOS Access Key ID / Secret
Access Key. A speech key alone does not authorize object storage. The application
uses file recognition 2.0; no model ID or arbitrary ASR upload URL is required.

**Save** stores the configuration locally. **Save and test** also initializes or
verifies private storage and sends a public audio sample for a billable service
check. Read the displayed charge notice before confirming. Successful testing
does not enable automatic upload by itself: select transcription in recording
preparation. Blank credential inputs preserve saved values.

Default initialization uses private standard storage in Beijing and expiration
rules scoped to this installation. Advanced existing storage must meet the
application's private-storage checks. Keep credentials available for unfinished
jobs and deletion retries. For the storage design and historical account tests,
see [the implementation plan](VOLCENGINE_TRANSCRIPTION_REFACTOR_PLAN.md).

Choose **Auto** for speech-language detection or one of the supported languages.
Enable AI processing only if you also want the configured text model to polish
and organize the transcript. Recording and transcription can be used without AI.

## Find, export, and retry results

Open **Transcription Results** next to Start Audio Recording in the menu bar or
tray, or follow the matching history item's transcript action. Search and filter
audio/video tasks, select a result, and inspect its original transcript, polished
text, or organized notes. Copy and Save/export act on the selected artifact.
Transcript exports retain timestamps; organized notes retain source references.

Closing a result window does not cancel background processing. Results persist
across app relaunch and are retained independently of clipboard history. Deleting
source media or allowing history to expire does not delete saved transcripts.

| Situation | Expected behavior / next step |
| --- | --- |
| Local audio saving fails | Recovery media is retained; quitting may be cancelled so saving can be retried. |
| Submission is interrupted or its outcome is uncertain | Recovery queries the persisted request ID rather than automatically submitting another paid job. |
| A terminal cloud failure requires a fresh submission | Review and explicitly confirm the resubmission charge prompt. |
| AI processing fails | The original transcript remains available; retry AI from saved text without repeating speech recognition. |
| Cloud deletion is pending | Background maintenance retries cleanup using the job's original account. |

Long audio is split into non-overlapping parts, each limited to four hours and
256 MiB, while retaining absolute timestamps. Split points favor quieter audio
but do not guarantee sentence boundaries. System and microphone source roles
remain distinct; speaker labels are scoped to each part, not a verified identity.

## Data and credentials

Selected audio is uploaded directly to your private TOS storage for the speech
service to retrieve. Video frames are not uploaded. Temporary signed retrieval
URLs expire after 24 hours; immediate object deletion and independent retries
are supplemented by a two-day expiration rule. Cleanup failure is distinct from
transcription failure; cancellation cannot reverse charges already incurred.

Optional AI processing sends transcript text and segment IDs to the configured
LLM endpoint. It does not send media files, local paths, or video frames. ShotPaste
operates no upload relay, and cloud service charges belong to your own account.

macOS stores transcription credentials in variant-isolated local UserDefaults
profiles, **not Keychain encryption**. Windows uses current-user DPAPI protection,
including saved job account snapshots. Both exclude credentials from configuration
exports and diagnostics. Debug and Release keep separate application data.
Transcripts and notes are private local content; consider them when managing
backups or sharing exported files. See [the security model](../SECURITY.md#security-model).
