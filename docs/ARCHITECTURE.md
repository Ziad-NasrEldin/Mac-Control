# Architecture

Mac Control is a single-process AppKit menu-bar app (no Dock icon) written in Swift, built with Swift Package Manager. Its only third-party dependency is [FluidAudio](https://github.com/FluidInference/FluidAudio), which runs NVIDIA Parakeet on the Apple Neural Engine via Core ML.

## The pipeline

```
key down ──► mic on ─────────────────────────────► key up ──► Parakeet (~50 ms) ──► transcript
   │                                                                                    │
   ├─► warm up the HTTPS connection                                                     ▼
   ├─► browser: page links/buttons, title, open tabs  (AppleScript → JavaScript)   exact phrase? ──yes──► run
   └─► any app: menu bar + front-window controls      (Accessibility API)              │ no
                                                                                       ▼
                                                      build ≤255 options ──► Decisions API (gpt-6-luna)
                                                                                       │ error
                                                                                       ▼
                                                                         local Decider (pplx-decider-flash)
                                                                                       │
                                               confidence < picker threshold ──► top-3 picker
                                               risky & < confirm threshold   ──► confirm
                                                                                       │
                                                         record undo ──► run steps in order ──► history
```

Everything that can be prepared while you're still talking is: the transcript is the only thing the decision has to wait for.

## Source map

`Sources/VoiceControl/`

| File | Responsibility |
|---|---|
| `main.swift` | Bootstraps `NSApplication` as an accessory (menu-bar only) app |
| `Controller.swift` | The app delegate: menu bar, hotkey, routing (picker → exact phrase → API → fallback), building options, confirm/pick flow, running chained steps, history |
| `Speech.swift` | `ParakeetEngine` (model download/load/transcribe) and `Listener` (AVAudioEngine capture, 16 kHz resampling, pre-roll ring buffer, levels, Apple Speech fallback) |
| `FastPath.swift` | Exact-phrase matcher: normalization, phrase table, app open/quit, volume levels |
| `Decisions.swift` | OpenAI Decisions client, cached catalog, response parsing, credit estimate |
| `LocalDecider.swift` | Perplexity Decider client and the option shortlist for it |
| `NativeUI.swift` | Reading menu items and window controls through the Accessibility API, pressing them |
| `Browser.swift` | AppleScript/JavaScript bridge: page elements, tabs, tab switching, search query extraction |
| `Windows.swift` | Window commands: macOS Window-menu tiling, frames, displays |
| `System.swift` | Volume, brightness, media keys, lock, screenshots, dark mode, Do Not Disturb, AppleScript and tool runners |
| `Keyboard.swift` | Synthesized key events and Unicode typing |
| `Undo.swift` | Capturing how to reverse each action before it runs; performing undo |
| `Shortcuts.swift` | Listing and running the user's Shortcuts |
| `Overlay.swift` | The floating HUD, level meter, sounds |
| `Prefs.swift` | Preferences, hotkey definitions, Keychain storage, the global key catcher |
| `SettingsUI.swift` | SwiftUI Settings window: Setup, General, Macros, History |
| `Store.swift` | History and macros persisted as JSON |
| `Apps.swift` | Scanning installed applications |
| `Config.swift` | Constants, browser list, API key loading, logging |
| `SelfTest.swift` | End-to-end self-tests (`--selftest <name>`) |

## Actions

Every action is a string value, used as the option value sent to the model and dispatched by `Controller.perform(_:)`:

| Value | Example | Implemented with |
|---|---|---|
| `open:<App>` / `quit:<App>` | `open:Notes` | `NSWorkspace` / `NSRunningApplication.terminate()` |
| `window:<cmd>` | `window:left` | Accessibility API; tiling presses the app's own Window-menu item so macOS applies its margins |
| `system:<cmd>` | `system:volume=40` | Media-key events, AppleScript, `pmset`, key shortcuts |
| `browser:<cmd>` | `browser:newtab` | Key shortcuts; JavaScript via Apple Events for scrolling |
| `tab:<window>:<index>` | `tab:1:3` | AppleScript |
| `click:<n>` | `click:12` | JavaScript click on an element tagged during the page scan |
| `menu:<n>` / `ui:<n>` | `menu:7` | `AXPress` on the element captured at key-down |
| `shortcut:<name>` | `shortcut:Make QR Code` | `/usr/bin/shortcuts run` |
| `macro:<n>` | `macro:0` | Resolves each step (exact phrase, else a decision) and runs them |
| `undo`, `none` | | |

## Talking to the decision model

### OpenAI Decisions API

`POST https://api.openai.com/v1/decisions`, model `gpt-6-luna`. One `choice` question per step:

```json
{
  "model": "gpt-6-luna",
  "prompt_cache_key": "voicecontrol",
  "input": [
    {"role": "developer", "content": [{"type": "input_text", "text": "Actions available on this Mac (value — meaning):\nopen:Notes — Open or switch to Notes\n…"}]},
    {"role": "user", "content": [{"type": "input_text", "text": "User said: \"open notes\"\nFrontmost app: Finder"}]}
  ],
  "questions": [{
    "type": "choice", "name": "step1",
    "instructions": "The user spoke a voice command to control their Mac. Pick the single action they meant. …",
    "choices": [{"value": "open:Notes"}, …, {"value": "menu:7", "description": "Menu command in Calculator: View › Scientific"}]
  }]
}
```

The response gives `answers[i].choice`, `confidence` and `probabilities` (used by the picker), and `usage` including `cached_tokens`.

**Caching.** The API caches only the shared `input`, never `questions`. So the *stable* part of the option list (apps, system/window/browser commands, Shortcuts, macros) is described once in a developer message, the catalog, and those options carry only their value; the *dynamic* part (running apps, menus, controls, tabs, links) keeps its descriptions inline. About 2,100 of ~3,500 input tokens are then served from cache. Measured: accuracy and latency unchanged (~380 ms either way), cost lower.

**The 255-option limit.** A choice question accepts at most 255 options. Stable options always stay; dynamic ones are ranked by word overlap with the transcript and the best fill the remaining room.

**Chained commands.** When the transcript contains "and", "then" or a comma, up to three questions are sent ("which action matches the first/second/third part? … or none"). This wording was chosen after testing alternatives against the live API. Repeated steps are dropped.

### Local fallback: Perplexity Decider

`POST http://127.0.0.1:8080/v1/decisions`, model `pplx-decider-flash-latest`. A different shape:

```json
{
  "model": "pplx-decider-flash-latest",
  "state": "User said: \"open notes\"\nFrontmost app: Finder",
  "questions": {
    "step1": {"type": "choice", "instructions": "…", "criteria": {"open:Notes": null, "system:mute": null, "menu:7": "Menu command in Calculator: View › Scientific"}}
  }
}
```

Answers come back keyed by question name with `choice`, `confidence` and `probabilities`. Its time grows with prompt size (≈3 s at ~900 tokens, ≈12 s at ~3,200 tokens), so it gets a shortlist of ~80 options: every system/window/browser command, plus the 15 apps and 25 dynamic options most similar to the transcript by character trigrams. Self-explanatory values are sent without descriptions.

## Speech

- **Capture:** `AVAudioEngine` input tap, resampled to 16 kHz mono floats with FluidAudio's `AudioConverter`.
- **Recognition:** Parakeet TDT 0.6B (v2 English or v3 multilingual) through `AsrManager`, warmed up with one silent pass at load. Short clips are padded to 1 s. Typical transcription: ~45–50 ms.
- **Pre-roll (optional):** with *Keep mic ready*, the engine runs continuously and a ring buffer keeps the last 0.5 s, which is prepended to each command.
- **Fallback:** Apple's `SFSpeechRecognizer` if Parakeet fails to load; it falls back from on-device to server recognition (replaying the captured audio) when Dictation is disabled.

## Safety model

- **Confirm** — `quit:*`, `shortcut:*`, `system:lock`, `system:sleepdisplay`, `window:close` ask first when confidence is under the confirm threshold (exact phrases count as 100%).
- **Picker** — single-step results under the picker threshold show the top 3 (from `probabilities`).
- **Key catcher** — while a picker or confirmation is showing, a session event tap swallows only 1–3, Return, Enter and Esc (without modifiers), so answering doesn't type into the front app. It's removed as soon as the prompt closes.
- **Undo** — before each action runs, `captureUndo` records how to reverse it (previous volume, window frame, appearance, whether an app was running, …).

## Concurrency

The main thread owns UI and state. AppleScript runs on a serial `scriptQueue`, accessibility scans on `uiQueue`; a decision waits for both queues to drain so the snapshot is complete. The audio tap runs on Core Audio's thread and shares buffers with the main thread under a lock. Network calls use `URLSession` and hop back to the main thread.

## Signing and permissions

macOS ties Accessibility, Microphone, Automation and Keychain access to the app's code signature. `build.sh` signs with your **Developer ID** (hardened runtime, timestamp, entitlements for audio input and Apple Events), so these grants survive rebuilds. Without a Developer ID it falls back to a local self-signed identity, then ad-hoc. With ad-hoc signing, macOS asks again after every build. See [Development](DEVELOPMENT.md#signing).
