# Privacy

## Stays on your Mac

- **Your voice.** Audio is captured only while you hold the hotkey (or continuously in memory with *Keep mic ready*), transcribed on-device by Parakeet, and discarded. It is never written to disk or uploaded.
- **Exact phrases and typing mode.** These never contact any server.
- **The local fallback.** Decisions made by Perplexity's Decider app run entirely on your Mac.
- **History and macros.** Plain JSON files in `~/Library/Application Support/MacControl/`.
- **Your OpenAI key.** In the macOS Keychain.

## Sent to OpenAI (only for commands that need a decision)

| Data | Why |
|---|---|
| The transcript of the command | To decide what you meant |
| The front app's name, and the current page title in a browser | Context ("close this" means different things in different apps) |
| The list of possible actions: installed app names, running app names, your Shortcut names, macro phrases, the front app's menu items and button labels, open browser tab titles, link/button texts on the current page | The options the model chooses from |

No screenshots, page contents (beyond link and button labels), file contents or audio are sent. Requests carry `prompt_cache_key: "maccontrol"` so OpenAI can reuse the stable part of the option list. OpenAI's handling of API data is governed by its API data-usage policies.

## On disk for debugging

`~/Library/Logs/MacControl.log` records transcripts, chosen actions and timings, and `MacControl-last-request.json` holds the most recent request body. Delete them any time; **Command History → Clear** empties the history.
