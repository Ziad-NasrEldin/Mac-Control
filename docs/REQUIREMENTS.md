# Requirements

| | |
|---|---|
| macOS | 14 Sonoma or later (developed on macOS 27) |
| Mac | Apple Silicon (Parakeet runs on the Neural Engine) |
| Toolchain | Xcode Command Line Tools with Swift 6 (`xcode-select --install`) |
| Decision model | An OpenAI API key with access to the Decisions API (`gpt-6-luna`), **or** Perplexity's [Decider](CONFIGURATION.md#local-decider-fallback) app running locally, or both |
| Disk | ~450 MB for the speech model (downloaded on first launch) |

## Cost

OpenAI's Decisions API bills **$0.10 per 1M uncached input tokens** and doesn't charge for output. A typical command is ~3,500 input tokens, of which ~2,100 are served from the prompt cache — roughly **$0.0002–0.0004 per command**, or a few tens of cents for a thousand commands. Exact phrases and the local Decider cost nothing. The menu bar shows an estimate of your remaining balance (set it once from the menu).
