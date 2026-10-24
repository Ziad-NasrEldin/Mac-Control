# Troubleshooting

Start with **Settings → Setup** (every requirement with its status) and **Open Log** in the menu-bar menu.

## Nothing happens when I hold the hotkey

- Check **Accessibility** in Setup. If it says *not allowed* although the switch in System Settings is on, the entry belongs to an older build: select **Mac Control** in Privacy & Security → Accessibility, remove it with **–**, add `/Applications/Mac Control.app` with **+**, and relaunch.
- Make sure you're holding the **right** Option key and the hotkey chosen in Settings → General.

## "Didn't catch that"

The second line says why:

| Message | Fix |
|---|---|
| Mic is silent — check Microphone permission / input device | Allow the microphone in Setup; check the input device in System Settings → Sound |
| No speech recognized | Speak after the overlay appears; or turn on **Keep mic ready** so the first word isn't clipped |
| Speech recognition not allowed | Only happens if Parakeet failed to load and the Apple fallback is in use — allow Speech Recognition, or fix Parakeet (below) |

## The speech model doesn't load

Setup shows *Parakeet: loading…* during the first download (~450 MB). If it says *failed*, check your internet connection and the log, then quit and relaunch; the download resumes into `~/Library/Application Support/FluidAudio/`.

## Errors from OpenAI

| Overlay | Meaning |
|---|---|
| *OpenAI unavailable — asking the local Decider…* | OpenAI failed and the [local fallback](CONFIGURATION.md#local-decider-fallback) is answering (a few seconds) |
| You have no credits remaining | Add credits at platform.openai.com → Billing. The menu-bar counter turns red at $0. |
| Invalid 'questions[0].choices': array too long | Fixed in 2.0: options are capped at 255. Rebuild if you still see it. |
| Error: … and *Local Decider: …* together | Both are unavailable: fix the OpenAI key or credits, or start Decider.app |

## The local Decider isn't used

- Setup → **Local Decider (fallback)** must say *Ready*. If not, click **Open Decider** (or launch `/Applications/Decider.app`) and wait for its model to load.
- Settings → General → **Fallback** must be on, and the address must match Decider's port (default `http://127.0.0.1:8080`).
- If Decider requires an API key (`DECIDER_API_KEY`), unset it: Mac Control doesn't send one.

## It picked the wrong thing

- Say **"undo that"**.
- Raise **Show top 3 below** in Settings → General so unsure commands ask you instead.
- Be more specific with app-specific commands ("in Calculator, switch to scientific").
- For something you say often, add a **macro**: exact phrases are instant and always right.
- History shows what was heard and chosen, with confidence.

## Menus or buttons of an app aren't found

- The app must be in front when you press the hotkey.
- Some apps (games, custom-drawn UIs) don't expose controls to Accessibility. Their menus usually still work.
- Disabled menu items are skipped. Electron apps are asked to enable accessibility automatically; if one still exposes nothing, restart that app.

## Browser tabs, links or scrolling don't work

- Allow **Control *browser*** in Setup (Privacy & Security → Automation).
- Links and scrolling run JavaScript: enable **Allow JavaScript from Apple Events** (Chrome family: View → Developer; Safari: Develop menu).

## "Do not disturb" says to create a shortcut

macOS has no public API for Focus. In the Shortcuts app, create **Do Not Disturb On** and **Do Not Disturb Off**, each with a *Set Focus* action.

## macOS keeps asking for permissions after updating

The build isn't signed with a stable identity. Build with a Developer ID certificate (see [Development → Signing](DEVELOPMENT.md#signing)), then re-add the app to Accessibility once.

## A Keychain prompt appears

"Mac Control wants to use your confidential information…" appears when the app's signature changed since the key was saved. Click **Always Allow**, or re-enter the key in Setup.

## Upgrading from "Voice Control"

Earlier builds were called **Voice Control** (bundle id `local.voicecontrol`), the same name as Apple's built-in accessibility feature. On its first launch, Mac Control moves over your settings and credit counter, your history and macros (`~/Library/Application Support/VoiceControl` → `MacControl`) and your API key (Keychain), then removes the old copies.

macOS treats the renamed app as a new app, so grant these once more:

1. **Accessibility**: add `/Applications/Mac Control.app` in Privacy & Security → Accessibility (the list may call it Device Control and Data Access) and switch it on.
2. **Microphone**: click **Allow** when asked.
3. **Browsers**: click **OK** the first time it controls Safari or Chrome.

You can then remove the old **Voice Control** entries from those lists, and delete `/Applications/Voice Control.app` if it's still there.
