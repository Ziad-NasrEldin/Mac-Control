# Development

## Build

```bash
./build.sh
```

- Runs `swift build -c release --arch arm64` (first build also fetches FluidAudio, ~90 MB).
- Assembles `VoiceControl.app` (Info.plist, FluidAudio's resource bundle) and signs it — see [Signing](#signing).
- Output: `./VoiceControl.app`. Install with `ditto VoiceControl.app "/Applications/Voice Control.app"`.

Logs go to `~/Library/Logs/VoiceControl.log`. The last Decisions request is saved to `~/Library/Logs/VoiceControl-last-request.json`.

### Handy launch flags

```bash
# Run one action without speech or the API, then quit
open -n "/Applications/Voice Control.app" --args --perform window:nextdisplay
open -n "/Applications/Voice Control.app" --args --perform browser:search --heard "search for swift concurrency"

# Run a self-test suite (see below)
open -n "/Applications/Voice Control.app" --args --selftest native
```

## Self-tests

The tests drive the **installed app** against real apps, real audio and the real APIs, and log `TEST PASS` / `TEST FAIL` lines.

```bash
./selftest.sh native shortcuts fastpath   # installs ./VoiceControl.app, runs the suites in order, relaunches the app
```

| Suite | Checks | Touches |
|---|---|---|
| `native` | Reads Calculator's menus and buttons; "switch to scientific mode" and "press seven" through the API | Opens Calculator |
| `shortcuts` | Lists Shortcuts; missing-shortcut error; "make a QR code" picks the right one (not run) | — |
| `fastpath` | 15 exact phrases, including ones that must fall through to the API | — |
| `speech` | Parakeet transcribes sentences spoken by the system voice | — |
| `caching` | Catalog requests are answered correctly and served from the prompt cache | — |
| `limit` | 300 extra menu items are trimmed to 255 and the right one survives | Opens Calculator |
| `picker` | Low-confidence picker by key press and by voice | Volume (restored) |
| `confirm` | Esc cancels and Return confirms a risky quit | Opens and quits Calculator |
| `undo` | Volume, window snap and app-open undo | Volume (restored), opens Chess |
| `mic` | Cold vs ready mic start, pre-roll, level meter, sounds | Microphone |
| `keychain` | Key is in the Keychain, plain-text file gone | — |
| `macros` | A macro runs both steps and lands in history | Volume (restored) |
| `typing` | Unicode typing into a focused text field | Shows a small window |
| `settings` | Settings window, Setup checks, live preference changes | Shows Settings |
| `fallback` | Bad key / no key → local Decider; chained command; both down → error | Volume (restored); needs Decider.app running |

The full run takes a few minutes and costs well under a cent in API usage. Don't type while `typing` runs, since it needs keyboard focus.

## Signing

`build.sh` picks the first available identity:

1. **Developer ID Application** — hardened runtime, secure timestamp, `VoiceControl.entitlements` (audio input and Apple Events). Accessibility, Microphone, Automation and Keychain grants survive rebuilds because macOS matches your Team ID.
2. **"Voice Control Local Signing"** — a self-signed certificate in your login keychain. Grants survive rebuilds, but Keychain items may prompt.
3. **Ad-hoc** — works, but macOS forgets every permission after each build.

After switching identities, remove Voice Control from Privacy & Security → Accessibility and add it again once, because the old entry belongs to the old signature.

## Releasing (notarization)

Only needed to give the app to other people. Store your notarization credentials once (this asks for an app-specific password from appleid.apple.com):

```bash
xcrun notarytool store-credentials voicecontrol-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

Then:

```bash
./release.sh    # builds, notarizes, staples, verifies with Gatekeeper, writes VoiceControl-<version>.zip
```

Set `NOTARY_PROFILE` to use a different credentials profile. The version comes from `CFBundleShortVersionString` in `build.sh`.

## Adding a command

1. **Pick a value**, e.g. `system:nightshift`.
2. **Offer it**: add a `Choice` to `systemChoices` in `System.swift`, or to `windowChoices` / `Controller.browserChoices`. Write the description the way people talk ("Turn Night Shift on / warmer screen colors"); the model matches against it.
3. **Run it**: handle it in `performSystem` (or `performWindow`, `browserCommand`, or `Controller.perform` for a new prefix).
4. **Make it instant** (optional): add common exact phrasings in `FastPath.phrases`.
5. **Make it undoable** (optional): return an `UndoStep` from `captureUndo` in `Undo.swift`.
6. **Mark it risky** (optional): add it to `Controller.isDestructive`.
7. **Test it**: `open -n "/Applications/Voice Control.app" --args --perform system:nightshift`, then add a case to a self-test suite.

Stable options belong in the cached catalog (`inCatalog: true`). Anything that changes from moment to moment should be a dynamic option with its description inline.

## Project layout

```
Package.swift                 SwiftPM manifest (FluidAudio dependency, Swift 5 language mode)
Sources/VoiceControl/         App sources — see docs/ARCHITECTURE.md
VoiceControl.entitlements     Hardened-runtime entitlements
build.sh                      Build, bundle, sign
selftest.sh                   Install and run self-test suites
release.sh                    Notarize and package
docs/                         Documentation
```
