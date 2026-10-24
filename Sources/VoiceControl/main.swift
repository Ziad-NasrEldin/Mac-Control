// VoiceControl — hold ⌘ + Right Option, speak, release. Speech → OpenAI Decisions API → action.
import AppKit

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
