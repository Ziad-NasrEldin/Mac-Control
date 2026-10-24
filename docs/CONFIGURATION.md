# Configuration

Open **Settings** from the menu-bar icon (or ⌘, while its menu is open). Changes apply immediately.

## Setup tab

A live checklist that refreshes every 2 seconds:

| Check | Fix button |
|---|---|
| OpenAI API key | Paste it into the field below and **Save to Keychain** |
| Microphone | Asks, or opens Privacy & Security → Microphone |
| Accessibility | Opens Privacy & Security → Accessibility |
| Speech model | Shows Parakeet's download/load status |
| Local Decider (fallback) | Opens Decider.app if it isn't running |
| Control *browser* (one row per running browser) | Asks, or opens Privacy & Security → Automation |

The Setup tab opens by itself at launch if the key, the microphone or Accessibility is missing.

## General tab

### Hotkey

| Option | Hold |
|---|---|
| **⌘ + Right ⌥** (default) | Command and the right Option key, in either order |
| ⌃ + Right ⌥ | Control and the right Option key |
| Right ⌥ alone | Only the right Option key (left Option still types special characters) |

Add **⇧ Shift** while holding to switch to typing mode.

### Speech

| Setting | Default | Notes |
|---|---|---|
| Model | Parakeet v2 — English | v3 understands 25 European languages; switching downloads it once |
| Keep mic ready | Off | Keeps the mic open and buffers the last 500 ms, so the first word is never clipped (mic start 0 ms instead of ~170 ms). The orange mic indicator stays on. |

### Safety

| Setting | Default | Meaning |
|---|---|---|
| Show top 3 below | 50% | Single commands under this confidence show a picker instead of running |
| Confirm risky actions below | 90% | Quit, lock, sleep display, close window and Shortcuts ask first under this confidence |
| Always confirm | Off | Ask before every risky action, however sure |

### Fallback when OpenAI fails

| Setting | Default |
|---|---|
| Ask Perplexity's local Decider | On |
| Decider address | `http://127.0.0.1:8080` |

### Feedback

| Setting | Default |
|---|---|
| Overlay position | Top of screen (or bottom) |
| Sounds | On — a soft tick when listening, pop on success, a low tone on failure |
| Launch at login | Off |

## Macros tab

Phrase → comma-separated steps, each an ordinary command. See [Commands → Macros](COMMANDS.md#macros-and-aliases).

## History tab

The last 500 commands with what was heard, what ran, confidence, speech and decision time, and whether it was an exact phrase (`local`), the API (`api`), the local model (`local-ai`), a picker choice (`picked`) or typing (`typed`). The header shows totals and averages.

## Credit counter

OpenAI doesn't let project API keys read the remaining balance, so the menu bar shows an **estimate**: the balance you enter (**Set Credit Balance…**) minus the cost of each command, computed from the token usage the API returns. When OpenAI reports that credits are exhausted, it shows **$0** in red. **Open OpenAI Billing** opens the real balance.

Prices used: $0.10 per 1M uncached input tokens, output free (per OpenAI's Decisions docs), and an assumed $0.01 per 1M cached tokens (the cache-read rate isn't published). Override them with `defaults write io.github.ziadnasreldin.maccontrol priceInput -float …` / `priceCached`.

## Local Decider fallback

[Perplexity's Decider](https://www.perplexity.ai) app runs `pplx-decider-flash` (a ~4B model) on your Mac and serves a decisions API on `127.0.0.1:8080`. Mac Control uses it automatically when OpenAI fails for any reason — error, outage, no credits, or no key.

- It's slower: about **3–4 s** per command (about 10 s for a three-step chain) instead of ~0.5 s. To keep it that fast, Mac Control sends it a shortlist of ~80 options: all system, window and browser commands, plus the 15 apps and 25 menus/buttons/Shortcuts most similar to what you said.
- It's free and fully offline.
- It must be running. Add **Decider** to System Settings → General → Login Items to keep it available.
- Decider's own settings live in its config file and `DECIDER_*` environment variables (`DECIDER_PORT`, `DECIDER_HOST`, `DECIDER_CONFIG`, …). If you change its port, update **Decider address**. Mac Control doesn't send an API key, so leave `DECIDER_API_KEY` unset.

## The OpenAI key

Stored in the macOS Keychain (service `io.github.ziadnasreldin.maccontrol`, account `openai-api-key`). The `OPENAI_API_KEY` environment variable overrides it. A key in the legacy plain-text file `~/.config/voicecontrol/openai_key` is moved into the Keychain on launch and the file deleted.

## Files on disk

| Path | What |
|---|---|
| `~/Library/Logs/MacControl.log` | Activity log (menu → **Open Log**) |
| `~/Library/Logs/MacControl-last-request.json` | The most recent Decisions request, for debugging |
| `~/Library/Application Support/MacControl/history.json` | Command history |
| `~/Library/Application Support/MacControl/macros.json` | Your macros |
| `~/Library/Application Support/FluidAudio/` | Parakeet speech models (~450 MB each) |
| `~/Library/Preferences/io.github.ziadnasreldin.maccontrol.plist` | Settings and credit counter |

## All preference keys

`defaults read io.github.ziadnasreldin.maccontrol` shows them:

| Key | Type | Default |
|---|---|---|
| `hotkey` | `cmdRightOption` · `ctrlRightOption` · `rightOption` | `cmdRightOption` |
| `speechModel` | `v2` · `v3` | `v2` |
| `pickerThreshold` | 0–1 | 0.5 |
| `confirmThreshold` | 0–1 | 0.9 |
| `alwaysConfirm` | bool | false |
| `overlayPosition` | `top` · `bottom` | `top` |
| `sounds` | bool | true |
| `keepMicReady` | bool | false |
| `localFallback` | bool | true |
| `localDeciderURL` | URL | `http://127.0.0.1:8080` |
| `creditBalance`, `creditSpent`, `creditCalls`, `creditExhausted` | — | credit counter state |
| `priceInput`, `priceCached` | $ per 1M tokens | 0.10, 0.01 |
