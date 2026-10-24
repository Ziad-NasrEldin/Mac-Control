// Persistent command history and the user's macros/aliases, as JSON in Application Support.
import Foundation
import Combine

/// A phrase that runs one or more spoken commands, e.g. "work mode" → ["open Slack", "open Mail"].
/// One step makes it an alias.
struct Macro: Codable, Identifiable, Hashable {
    var id = UUID()
    var phrase: String
    var steps: [String]
}

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let heard: String
    let actions: [String]
    let labels: [String]
    let confidence: Double?
    let sttMs: Int?
    let decideMs: Int?
    /// "local", "api" or "typed".
    let source: String
    let tokens: Int
    let ok: Bool
}

final class Store: ObservableObject {
    static let shared = Store()
    @Published var macros: [Macro] = [] { didSet { save(macros, "macros.json") } }
    @Published private(set) var history: [HistoryEntry] = []
    let maxHistory = 500

    let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VoiceControl")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private init() {
        macros = load("macros.json") ?? []
        history = load("history.json") ?? []
    }

    func add(_ e: HistoryEntry) {
        history.insert(e, at: 0)
        if history.count > maxHistory { history.removeLast(history.count - maxHistory) }
        save(history, "history.json")
    }

    func clearHistory() { history = []; save(history, "history.json") }

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        try? enc.encode(value).write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    // MARK: Stats

    struct Stats { let count: Int; let localShare: Double; let avgSpeech: Int?; let avgDecide: Int?; let avgTotalAPI: Int? }

    var stats: Stats {
        let h = history.filter { $0.source != "typed" }
        func avg(_ xs: [Int]) -> Int? { xs.isEmpty ? nil : xs.reduce(0, +) / xs.count }
        let api = h.filter { $0.source == "api" }
        return Stats(count: h.count,
                     localShare: h.isEmpty ? 0 : Double(h.filter { $0.source == "local" }.count) / Double(h.count),
                     avgSpeech: avg(history.compactMap(\.sttMs)),
                     avgDecide: avg(api.compactMap(\.decideMs)),
                     avgTotalAPI: avg(api.compactMap { e in e.decideMs.map { $0 + (e.sttMs ?? 0) } }))
    }
}
