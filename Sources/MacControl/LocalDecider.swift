// Fallback: Perplexity's Decider app running on this Mac (pplx-decider-flash), used when OpenAI fails.
// Its API differs from OpenAI's: `state` instead of `input`, and `questions` / `criteria` / answers are keyed maps.
import Foundation

final class LocalDecider {
    /// Read from Settings each time, so an edited address applies immediately.
    var baseURL: URL { URL(string: Prefs.shared.localDeciderURL) ?? URL(string: "http://127.0.0.1:8080")! }
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 45   // a ~4B model on-device takes a few seconds
        return URLSession(configuration: c)
    }()
    static let model = "pplx-decider-flash-latest"
    // Most apps and dynamic options are pre-filtered by similarity to what was said: ~90 options run in
    // ~3.7 s locally versus ~11 s for the full list, with the same answers in testing.
    static let maxApps = 15, maxDynamic = 25

    /// "ready · Qwen/Qwen3.5-4B" or why it isn't reachable.
    func health(_ done: @escaping (Bool, String) -> Void) {
        session.dataTask(with: baseURL.appendingPathComponent("health")) { data, _, err in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let ok = json?["status"] as? String == "ready"
            let detail = ok ? "Ready · \(json?["model"] as? String ?? "model")" : (err?.localizedDescription ?? "Not running — open Decider.app")
            DispatchQueue.main.async { done(ok, detail) }
        }.resume()
    }

    static func trigrams(_ s: String) -> Set<String> {
        let t = Array(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        guard t.count >= 3 else { return [String(t)] }
        return Set((0...(t.count - 3)).map { String(t[$0..<$0 + 3]) })
    }

    /// Share of `candidate`'s trigrams that also occur in what was said.
    static func similarity(_ heard: String, _ candidate: String) -> Double {
        let c = trigrams(candidate)
        return Double(trigrams(heard).intersection(c).count) / Double(max(1, c.count))
    }

    /// Fixed system/window/browser commands always; the closest apps and dynamic options otherwise.
    /// Self-explanatory values go without a description to keep the prompt short.
    static func criteria(for choices: [Choice], heard: String) -> [String: Any] {
        var out: [String: Any] = [:]
        var apps: [Choice] = [], dynamic: [Choice] = []
        for ch in choices {
            let kind = ch.value.split(separator: ":").first.map(String.init) ?? ch.value
            switch kind {
            case "open": apps.append(ch)
            case "system", "window", "browser", "undo", "none": out[ch.value] = NSNull()
            default: dynamic.append(ch)
            }
        }
        for a in apps.sorted(by: { similarity(heard, String($0.value.dropFirst(5))) > similarity(heard, String($1.value.dropFirst(5))) }).prefix(maxApps) {
            out[a.value] = NSNull()
        }
        for d in dynamic.sorted(by: { similarity(heard, $0.description) > similarity(heard, $1.description) }).prefix(maxDynamic) {
            out[d.value] = d.description
        }
        return out
    }

    func decide(heard: String, input: String, choices: [Choice], steps: Int, instructions: (Int) -> String,
                completion: @escaping (DecisionResult) -> Void) {
        let crit = LocalDecider.criteria(for: choices, heard: heard)
        var questions: [String: Any] = [:]
        for i in 1...max(1, steps) {
            questions["step\(i)"] = ["type": "choice", "instructions": instructions(i), "criteria": crit]
        }
        var r = URLRequest(url: baseURL.appendingPathComponent("v1/decisions"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": LocalDecider.model, "state": input, "questions": questions])
        let start = DispatchTime.now()
        session.dataTask(with: r) { data, resp, err in
            let ms = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            var result = DecisionResult(choice: nil, confidence: nil, ms: ms, error: err.map { "Local Decider: \($0.localizedDescription)" })
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let e = json["error"] as? [String: Any] {
                    result = DecisionResult(choice: nil, confidence: nil, ms: ms, error: "Local Decider: \(e["message"] as? String ?? "error")")
                } else if let answers = json["answers"] as? [String: [String: Any]] {
                    let ordered = (1...max(1, steps)).compactMap { answers["step\($0)"] }
                    let first = ordered.first
                    result = DecisionResult(choice: first?["choice"] as? String,
                                            confidence: (first?["confidence"] as? NSNumber)?.doubleValue, ms: ms, error: nil)
                    result.steps = ordered.compactMap { a in
                        guard let c = a["choice"] as? String, c != "none" else { return nil }
                        return (c, (a["confidence"] as? NSNumber)?.doubleValue)
                    }
                    result.alternatives = ((first?["probabilities"] as? [String: NSNumber]) ?? [:])
                        .filter { $0.key != "none" }
                        .map { (value: $0.key, probability: $0.value.doubleValue) }
                        .sorted { $0.probability > $1.probability }
                }
                result.inputTokens = ((json["usage"] as? [String: Any])?["input_tokens"] as? NSNumber)?.intValue ?? 0
            } else if err == nil {
                result = DecisionResult(choice: nil, confidence: nil, ms: ms,
                                        error: "Local Decider: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let summary = result.steps.map { "\($0.choice) (\($0.confidence.map { String(format: "%.2f", $0) } ?? "?"))" }
            log("local decided \(steps) step(s): \(summary.joined(separator: " → ")) options=\(crit.count) tokens=\(result.inputTokens) \(ms)ms\(result.error.map { " error=\($0)" } ?? "")")
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
