# Commands

Speak naturally; you don't have to match these words exactly. Anything that isn't an [exact phrase](#exact-phrases-instant) is sent to the decision model together with the list of actions available right now, and it picks the one you meant. Speech-recognition slips are fine ("chat GBT" still opens ChatGPT).

Hold **⌘ + Right ⌥** (or your chosen [hotkey](CONFIGURATION.md#hotkey)) while speaking. Add **⇧** to [type](#typing-mode) instead.

## Apps

| Say | Does |
|---|---|
| "open Notes", "launch Calculator", "switch to Safari" | Opens the app or brings it to the front |
| "quit Spotify", "close Xcode" | Quits a running app *(asks first unless certain)* |

Apps come from `/Applications`, `/Applications/Utilities`, `/System/Applications` (and its Utilities) and `~/Applications`. Use **Rescan Apps and Shortcuts** in the menu after installing something new (it also rescans every 10 minutes).

## Windows

Acts on the front window.

| Say | Does |
|---|---|
| "maximize", "fill the screen", "make it bigger" | macOS **Window → Fill** (keeps the system's margin around the window) |
| "snap left" / "right" / "top half" / "bottom half" | Tiles to that half (macOS tiling) |
| "center the window" | Centers it |
| "move this to my other monitor", "next display" | Moves it to the next display, keeping its size and relative position |
| "minimize" | Minimizes to the Dock |
| "full screen" | Toggles full screen |
| "close the window" | Closes it *(asks first unless certain)* |

## Menus and buttons in any app

While you hold the key, Mac Control reads the front app's **menu bar** and the **buttons, checkboxes, tabs and pop-ups** in its front window. You can then name any of them:

| Say | In | Does |
|---|---|---|
| "switch to scientific mode" | Calculator | View › Scientific |
| "press seven" | Calculator | Clicks the 7 button |
| "export as PDF" | Pages, Preview… | File › Export as PDF… |
| "show the sidebar" | Finder, Mail… | View › Show Sidebar |

The Apple menu and the system-wide Services menu are skipped. Electron apps (Slack, VS Code, Claude…) are asked to expose their accessibility tree automatically.

## Browser

Works with Safari, Chrome, Arc, Brave, Edge, Vivaldi and Opera. Navigation commands also work when the browser isn't in front (it's brought forward).

| Say | Does |
|---|---|
| "go back", "go forward", "reload" | ⌘[ · ⌘] · ⌘R |
| "new tab", "close tab", "reopen closed tab" | ⌘T · ⌘W · ⇧⌘T |
| "scroll down", "scroll up" | Scrolls ~80% of a screen |
| "go to the GitHub tab" | Switches to the open tab with that title (up to 60 tabs) |
| "click sign in", "open the pricing link" | Clicks a visible link or button on the page (up to 120) |
| "search for flights to Cairo", "google …", "look up …" | Opens a Google search |

Clicking links and scrolling run JavaScript in the page, which needs **View → Developer → Allow JavaScript from Apple Events** (Chrome family) or **Develop → Allow JavaScript from Apple Events** (Safari). Without it, scrolling falls back to Page Up/Down.

## System

| Say | Does |
|---|---|
| "volume up" / "louder", "volume down" / "quieter" | Media keys (shows the system HUD) |
| "volume 40", "set the volume to 75 percent" | Sets it (rounded to the nearest 10%) |
| "mute", "unmute" | Toggles mute |
| "brighter", "dimmer" | Display brightness |
| "play", "pause", "next song", "previous track" | Media keys |
| "dark mode", "light mode", "toggle dark mode" | Appearance |
| "take a screenshot", "screenshot an area", "screenshot tool" | ⇧⌘3 · ⇧⌘4 · ⇧⌘5 |
| "lock the screen" | ⌃⌘Q *(asks first unless certain)* |
| "turn off the display" | Sleeps the display *(asks first unless certain)* |
| "do not disturb on" / "off" | Runs the Shortcuts named **Do Not Disturb On** / **Do Not Disturb Off** (create them once with a *Set Focus* action — macOS has no public API for Focus) |

## Shortcuts

Every shortcut in the Shortcuts app is available by name: "make a QR code" runs **Make QR Code**. Because shortcuts can do anything (call people, send messages), Mac Control **asks before running one** unless the model is at least 90% sure (adjustable).

## Macros and aliases

Define your own phrases in **Settings → Macros**. Each step is an ordinary command:

| Phrase | Steps |
|---|---|
| work mode | open Slack, open Mail, open Google Chrome |
| focus | do not disturb on, quit Slack |
| tunes | open Music, play |

A macro with one step is an alias. Saying the exact phrase runs it instantly; the model can also choose it for close paraphrases.

## Acting while you talk

With **Act while I'm still talking** on (the default), you don't have to finish the sentence before things happen. The transcript updates every ~0.15 s; a clause runs as soon as it's finished — followed by "and", "then", a comma, a full stop or a question mark — and the clause you're still saying runs as soon as it's unambiguous:

> "Alright, can you **open up the Notes** app for me and create a new note that says call mom at six"
>
> Notes opens as you say "Notes" · a new note is created · "Call mom at six" is typed in when you pause (hands-free) or let go of the key

- **A pause ends the command.** About 0.7 s of quiet runs whatever is left of the sentence, while you keep holding the key; keep talking for the next command. Letting go does the same. Dictated text waits until you let go, so the held keys can't turn it into shortcuts.
- If the final transcript words a clause differently or it grew after running ("open Notes" → "open Notes in a new window"), it's decided again and runs only if that gives something new.
- The clause still being spoken runs early only when it's settled: an exact phrase, or the same confident (≥75%) answer from two transcripts in a row — and only if nothing longer could still follow (not "Safari" while "Safari Technology Preview" is installed, not "dark mode" since "dark mode off" exists). Numbers ("volume 4…"), websites and searches always wait for the end.
- Finished clauses run early when they're exact phrases or confident (≥60%) and harmless. Risky or unclear ones wait for the pause, with the usual confirm and picker.
- Talk around the command is ignored: "Alright", "now", "can you", "please", "let's", "once you're there", "for me". Clauses that are only that ("Great, great.", "Thank you") do nothing.
- When a search starts ("can you Google search…"), the browser comes forward right away; the search runs when the query is finished.
- Each command is decided knowing the last few you gave (within two minutes), so "once you're there…" and "in it…" make sense.
- After a step opens or switches apps, the next clause is decided against **that** app's menus and buttons.
- If another app grabs focus mid-command (a game, a notification), the remaining steps stop and nothing is typed: the overlay says which app took focus.
- The overlay shows the live transcript with ✓ next to steps already done, and afterwards how long before you let go the first action ran.

## Hands-free

**Tap** the hotkey (press and release without speaking) and the overlay says *Go ahead, I'm listening…*. Talk normally; every pause runs a command, in the order you said them:

> "Can you open up the Notes app?" … "Create a new note." … "Let's make the title say hello." … "Great. Now open X.com." … "Thank you."

- Tap the hotkey again, or say **"stop listening"** / "that's all", to end. It also ends after 90 s without a command.
- It hears everything said near the Mac, so only what reads like a command (starts with an action word, or is an exact phrase) is decided; acknowledgements ("okay", "great", "thank you") and other talk are ignored, and a command it can't place fails quietly (no error sound).
- A confirmation can be answered by voice: "yes" / "do it" or "no" / "cancel". The picker takes "one", "two", "three".
- Needs Parakeet (it's what notices the pauses). Turn the tap off in Settings → General → *Tap the hotkey to listen hands-free*.
- Websites: "open X.com", "go to github dot com" open in your browser.

## Dictated text

Anything after these words is typed, not interpreted, after the steps before it run:

| Marker | Example |
|---|---|
| "that says", "which says", "saying", "with the text" | "create a new note **that says** buy milk" |
| "type", "write", "dictate" (at the start or after "and"/"then") | "open TextEdit **and type** dear team" |

The first letter is capitalized; punctuation comes from the speech model. Text is only typed into the app the command was aimed at. For dictation without any command, use [typing mode](#typing-mode).

## Chained commands

Join commands with "and", "then" or a comma — up to three steps:

> "open Safari, make a new tab and search for the weather"

Steps run in order; after an "open" step Mac Control waits for the app to come to the front before continuing.

## Undo

Say **"undo that"** (or use **Undo Last Command** in the menu) to reverse the last command:

| Undoes | By |
|---|---|
| Volume / mute changes | Restoring the previous level and mute state |
| Dark/light mode | Restoring the previous appearance |
| Brightness, media keys | Pressing the opposite key |
| Window move, resize, tile, maximize, center | Restoring the exact previous frame |
| Minimize, full screen | Restoring the window |
| Open an app | Quitting it (if it wasn't running) or switching back |
| Quit an app | Reopening it |
| New/close/reopen tab, back/forward, scroll | The opposite browser command |

Menu items, button clicks, tab switches, searches and Shortcuts can't be undone.

## When it isn't sure

- **Low confidence** (below 50% by default): the overlay lists the top 3 interpretations — press **1**, **2** or **3**, or hold the hotkey and say the number. **Esc** cancels.
- **Risky actions** (quit, lock, sleep display, close window, Shortcuts) below 90% confidence: the overlay asks — **Return** or the hotkey confirms, **Esc** cancels. Exact phrases never ask.

Both thresholds are in **Settings → General → Safety**.

## Typing mode

Hold **⇧ + ⌘ + Right ⌥** (Shift can be added at any point while holding) and speak. The transcript is typed into whatever field has focus, followed by a space. With Bark 3.0 Pro installed it makes the transcript (Settings → General → Speech); otherwise Parakeet does. No API call is made, the clipboard isn't touched, and accents and emoji are typed correctly.

## Exact phrases (instant)

These are matched on your Mac in microseconds and never reach an API (punctuation, "please", "the" and similar filler words are ignored):

- `open|launch|start|switch to|go to|show <app name>`
- `quit|close|exit|kill <running app name>`
- `volume <0–100>`, `set volume to <n> percent`
- mute · unmute · volume up · volume down · louder · quieter · brighter · dimmer
- play · pause · resume · next song · previous song · skip track
- lock screen · sleep display · screenshot · take a screenshot · dark mode · light mode
- minimize · maximize · fill · full screen · center · left half · right half · top half · bottom half · close window · next display · move to other display · other screen
- go back · back · go forward · reload · refresh · new tab · close tab · reopen tab · scroll down · scroll up · page down · page up
- undo · undo that
- the exact phrase of any of your macros
