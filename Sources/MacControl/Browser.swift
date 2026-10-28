import AppKit
import ApplicationServices

// MARK: - Browser bridge (AppleScript → page JavaScript)

struct PageElement: Decodable { let i: Int; let t: String; let k: String }

let collectJS = """
(()=>{document.querySelectorAll('[data-vc]').forEach(e=>e.removeAttribute('data-vc'));\
const out=[],seen=new Set();let i=0;\
for(const e of document.querySelectorAll('a[href],button,[role=button],[role=link],[role=tab],[role=menuitem],input[type=submit],input[type=button],summary')){\
if(i>=\(maxPageElements))break;const r=e.getBoundingClientRect();\
if(r.width<2||r.height<2||r.bottom<0||r.top>innerHeight||r.right<0||r.left>innerWidth)continue;\
const s=getComputedStyle(e);if(s.visibility==='hidden'||s.display==='none')continue;\
const t=(e.getAttribute('aria-label')||e.innerText||e.value||e.title||'').trim().replace(/\\s+/g,' ').slice(0,80);\
if(!t)continue;const key=t.toLowerCase();if(seen.has(key))continue;seen.add(key);\
e.setAttribute('data-vc',i);out.push({i:i,t:t,k:e.tagName==='A'||e.getAttribute('role')==='link'?'link':'button'});i++;}\
return JSON.stringify(out);})()
"""

func appleScriptEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

/// Runs JS in the front tab of the given browser. Must be called on `scriptQueue`.
func runJS(_ js: String, app: NSRunningApplication, kind: BrowserKind) -> String? {
    guard let bid = app.bundleIdentifier else { return nil }
    let esc = appleScriptEscape(js)
    let src: String
    switch kind {
    case .safari: src = "tell application id \"\(bid)\" to do JavaScript \"\(esc)\" in current tab of front window"
    case .chromium: src = "tell application id \"\(bid)\" to execute active tab of front window javascript \"\(esc)\""
    }
    var err: NSDictionary?
    let result = NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let err { log("AppleScript error: \(err)") }
    return result?.stringValue
}

let scriptQueue = DispatchQueue(label: "maccontrol.applescript")

struct BrowserTab { let window: Int; let index: Int; let title: String }
let maxTabs = 60

/// Lists the open tabs of every window. Must be called on `scriptQueue`.
func listTabs(app: NSRunningApplication, kind: BrowserKind) -> [BrowserTab] {
    guard let bid = app.bundleIdentifier else { return [] }
    let titleOf = kind == .safari ? "name" : "title"
    let src = """
    tell application id "\(bid)"
      set out to ""
      repeat with w from 1 to count of windows
        repeat with t from 1 to count of tabs of window w
          set out to out & w & (ASCII character 9) & t & (ASCII character 9) & (\(titleOf) of tab t of window w) & linefeed
        end repeat
      end repeat
      return out
    end tell
    """
    var err: NSDictionary?
    guard let s = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue else {
        if let err { log("listTabs error: \(err)") }
        return []
    }
    return s.split(separator: "\n").prefix(maxTabs).compactMap { line in
        let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard f.count == 3, let w = Int(f[0]), let t = Int(f[1]) else { return nil }
        return BrowserTab(window: w, index: t, title: String(f[2]).trimmingCharacters(in: .whitespaces))
    }
}

func switchTab(app: NSRunningApplication, kind: BrowserKind, window w: Int, tab t: Int) {
    guard let bid = app.bundleIdentifier else { return }
    let select = kind == .safari ? "set current tab of window \(w) to tab \(t) of window \(w)"
                                 : "set active tab index of window \(w) to \(t)"
    runAppleScript("tell application id \"\(bid)\"\n\(select)\nset index of window \(w) to 1\nactivate\nend tell")
}

/// Pulls the search query out of e.g. "open Safari and search for cheap flights to Cairo".
func searchQuery(from heard: String) -> String {
    let pattern = #"(?i)^.*?\b(?:search(?:\s+(?:the\s+web|google|online))?(?:\s+for)?|google(?:\s+search)?(?:\s+for)?|look\s+up)\b\s*"#
    var q = heard.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    if q == heard { q = heard }
    // Drop anything chained after the query ("… and then open a new tab").
    if let r = q.range(of: #"(?i)\s*,?\s+(?:and\s+)?then\b.*$"#, options: .regularExpression) { q.removeSubrange(r) }
    q = q.replacingOccurrences(of: #"(?i)[\s,]*(?:for me|please)?[\s?.!,]*$"#, with: "", options: .regularExpression)
    return q.trimmingCharacters(in: CharacterSet(charactersIn: " .?!,"))
}
