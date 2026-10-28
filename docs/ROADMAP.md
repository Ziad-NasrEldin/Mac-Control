# Roadmap

Run any test with `./selftest.sh <name>` (names in brackets). Full suite: 86 checks in 17 suites, all passing. See [Development → Self-tests](DEVELOPMENT.md#self-tests).

## Control more of the Mac
- [x] 1. Menu items in any app — the front app's menu bar via Accessibility ("export as PDF", "scientific mode") [native]
- [x] 2. Click buttons in native apps — the front window's buttons, checkboxes, tabs, pop-ups ("press seven") [native]
- [x] 3. Run your Shortcuts — `shortcuts list` as options; risky, so asked first unless certain [shortcuts]
- [x] 4. Window management — minimize, close, full screen, maximize (macOS Fill, with margins), center, halves, next display
- [x] 5. System controls — volume, brightness, media keys, Do Not Disturb, lock, screenshots, dark mode, sleep display
- [x] 6. More browser actions — switch to tab by title, reopen closed tab, "search for …" (Google)
- [x] 7. Typing mode — add ⇧ while holding the hotkey; types the transcript into the focused field [typing]
- [x] 8. Chained commands — up to 3 steps per command, run in order

## Faster and more accurate
- [x] Act while still talking — live transcription; finished clauses run before you let go; next clause decided against the newly opened app [stream]
- [x] No need to let go — a pause ends each command; the clause still being spoken runs once it's settled; chatter and polite phrasing ignored [endpoint, live, utterance]
- [x] Hands-free — tap the hotkey, talk, pause between commands; "stop listening" ends it; recent commands give context
- [ ] Silero VAD (FluidAudio `VadManager`) instead of the energy gate, for noisy rooms
- [x] Dictated text inside commands — "…that says …", "type …"; typed only into the intended app [utterance, stream]
- [x] Exact phrases skip the API — matched locally in microseconds ("open notes", "volume 40", "undo that") [fastpath]
- [x] Prompt caching — stable action catalog sent as cached `input` (~2,100 tokens cached per call); same speed, cheaper [caching]
- [x] Low-confidence picker — under 50% (adjustable), shows the top 3; press 1–3 or say the number [picker]
- [x] ~~Switch to SpeechAnalyzer~~ — superseded: Parakeet (on-device, ~47 ms, no Dictation needed) does this better [speech]
- [x] Local fallback — Perplexity's Decider on this Mac answers when OpenAI fails, is out of credits or has no key (~3–4 s) [fallback]
- [x] Option limit — at most 255 options per question; the most relevant menus/controls/tabs/links are kept [limit]
- [x] Keep the mic ready — optional; 500 ms pre-roll, 0 ms start instead of ~174 ms [mic]

## Safety
- [x] Confirm risky actions — quit, lock, sleep display, close window, Shortcuts ask first when under 90% (or always, if set) [confirm]
- [x] "Undo that" — volume, dark mode, window moves/resizes, minimize, full screen, opened/quit apps, browser tabs/navigation [undo]

## Product polish
- [x] Settings window — hotkey (⌘/⌃ + Right ⌥ or Right ⌥ alone), speech model (English v2 / 25-language v3), thresholds, overlay position, sounds, launch at login [settings]
- [x] Setup screen — live status for API key, Microphone, Accessibility, speech model, and control of each running browser, with fix buttons [settings]
- [x] API key in Keychain — the plain-text file was migrated and deleted [keychain]
- [x] Developer ID signing + hardened runtime — permissions and Keychain access now survive rebuilds
- [ ] Notarization — `release.sh` is ready; needs your one-time `xcrun notarytool store-credentials` (only needed to share the app)
- [ ] Auto-updates — needs a place to host releases (e.g. GitHub Releases) before Sparkle can be wired in
- [x] Command history with timing stats; macros and aliases (Settings → Macros) [macros]
- [x] Feedback while talking — live mic-level waveform in the overlay; subtle sounds (toggle in Settings) [mic]
