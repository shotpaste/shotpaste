# Agent Mode (macOS MVP)

Agent Mode is a second ShotPaste product mode. One Shot captures content for the
user; Agent Mode uses a clean full-display capture as an observation, interprets
an intent, and performs a bounded sequence of locally approved Mac actions.

## Interaction

1. Turn on **Agent Mode** from the menu bar or Agent preferences.
2. Press **Option-A** (customizable). The shortcut is registered only while the
   mode is on, so it does not consume `å` or normal Option-A input while off.
3. ShotPaste captures and freezes every display while excluding its own UI.
4. Click an anchor, enter the task, then press Return. Shift-Return inserts a
   line break and Escape cancels.
5. The overlay closes before planning. Each action is followed by a new clean
   observation until the model completes, asks a question, fails, or is stopped.

After submission, a draggable translucent **Agent Activity** window appears on
the task display. It continuously shows the current phase and the auditable
observation, proposed action, approval, execution result, pause, completion, or
failure trail. It deliberately does not expose private model reasoning. Closing
the window only hides it; **Show Agent Activity** in the menu bar restores it.
Because it is a ShotPaste-owned window, it is excluded from every fresh Agent
observation and is never sent to the provider.

Any physical mouse, keyboard, drag, or scroll input pauses an executing Agent.
Escape remains the emergency stop while paused, and the menu bar always exposes
**Stop Agent Immediately** for an active session.

## Provider configuration

The Agent speaks two selectable upstream protocols (`api_protocol` in the TOML
configuration file, or the **API protocol** picker in Agent preferences):

- `openai` — OpenAI-compatible Chat Completions (default):

  ```text
  endpoint = https://api3.wlai.vip/v1/chat/completions
  model = gpt-5.6-luna
  send_images = true
  ```

- `anthropic` — Anthropic Messages API (`POST /v1/messages`, `x-api-key` /
  `Authorization: Bearer` auth, `anthropic-version: 2023-06-01`):

  ```text
  endpoint = https://api.anthropic.com
  model = claude-sonnet-5
  send_images = true
  ```

  The endpoint may be a host, a versioned base, an arbitrary gateway prefix, or
  a complete Messages URL. For example, `https://api.kimi.com/coding/` resolves
  to `https://api.kimi.com/coding/v1/messages`, while an existing
  `/v1/messages` suffix remains unchanged.

When Anthropic thinking mode is enabled, ShotPaste requests adaptive thinking
with high effort. If a compatible gateway explicitly rejects those modern
fields with HTTP 400, ShotPaste retries once with the legacy token-budget shape;
other bad requests are not retried as a different protocol. Turning thinking
off sends an explicit disabled value. Parallel tool use is disabled, and a
response containing more than one tool action is rejected locally.

The protocol, endpoint, model, reasoning mode, and clean-image capability are
editable, so the Agent is not tied to a named LLM vendor. HTTPS endpoints and
localhost HTTP endpoints are accepted. The API token is stored directly in
ShotPaste's application preferences and is displayed only as a masked
prefix/suffix. It remains absent from TOML exports, diagnostics, and audit
events. The settings UI can explicitly import `SHOTPASTE_LLM_API_KEY` from the
login shell; ShotPaste never reads shell startup files as an implicit background
action.

The current default model accepts tool calls and vision input, so clean screenshot
sending is on by default. It can be disabled for a text-only compatible provider;
ShotPaste still sends local Vision OCR, normalized anchor/display data, foreground
app/window data, and a sanitized Accessibility snapshot. The annotation anchor
and prompt UI are sent only as structured context and are never burned into the
image.

## Architecture and state

```mermaid
flowchart LR
  A["AgentModeController<br/>tray and shortcut lifecycle"] --> B["Clean multi-display capture"]
  B --> C["AgentAnnotationOverlay<br/>anchor and intent"]
  C --> D["AgentContextAssembler<br/>OCR, AX, app, coordinates"]
  D --> E["LLMProvider<br/>one tool decision"]
  E --> F["AgentPolicyEngine<br/>local approval gate"]
  F --> G["MacComputerDriver<br/>role-aware AX / CGEvent dispatch"]
  G --> B
```

`AgentSessionCoordinator` owns the state machine:

```text
idle → capturing → annotating → observing → planning
     → awaitingApproval / awaitingUser → executing → observing
     → paused / completed / failed
```

`InteractionLeaseCoordinator` prevents Agent and One Shot sessions from owning
global interaction surfaces at the same time. The provider cannot approve its
own actions; the policy engine and native approval presenter are separate local
boundaries.

## MVP action and safety boundary

Allowed model tools are limited to activating a running app/window, click,
double-click, right-click, text input, key chords, scroll, drag, wait, ask the
user, and report completion. Accessibility actions are preferred; normalized
coordinate CGEvents are a fallback. For frame-backed custom surfaces such as
rows, groups, and static labels, the driver uses the Accessibility element for
semantic targeting and policy evaluation, then dispatches a pointer CGEvent so
the application runs the same hit-testing path as a physical mouse. Native
semantic controls such as buttons continue to prefer AXPress. CGEvents are
marked so the user-activity monitor can distinguish Agent input from physical
input. An action result acknowledges input dispatch only; the planning model
must verify the expected state in the next fresh observation.

The local client blocks secure-field and password entry. It asks for explicit
approval before crossing into another application or performing actions that
look like sending, uploading, purchasing, deleting, publishing, changing
security settings, submitting forms, or moving Finder items. Arbitrary shell,
AppleScript, file deletion tools, MCP, background autonomy, and long-running
unattended sessions are not exposed.

## Storage

Agent sessions do not use screenshot or clipboard history. Text events and safe
action summaries are written under the separate `AgentSessions` application
support directory. Typed text is represented only by character count in action
audit summaries. Observation screenshots remain ephemeral unless the user turns
on **Retain session screenshots**; retention is off by default.
