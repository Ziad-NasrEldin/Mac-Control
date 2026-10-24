import Foundation

// MARK: - Decisions API

/// `inCatalog` choices are the stable part of the list: their meanings go once into the cached `input`
/// catalog and the question carries only their values.
struct Choice { let value: String; let description: String; var inCatalog = false }
struct DecisionResult {
    let choice: String?; let confidence: Double?; let ms: Int; let error: String?
    var errorCode: String? = nil
    var inputTokens = 0, outputTokens = 0
    /// One entry per step for chained commands, in order ("none" steps removed).
    var steps: [(choice: String, confidence: Double?)] = []
    /// Runner-up choices for the first step, most likely first ("none" excluded).
    var alternatives: [(value: String, probability: Double)] = []
    var cachedTokens = 0
}

// MARK: - Credits
// OpenAI doesn't expose the remaining balance to project keys, so: balance you enter − spend tracked from `usage`.

final class Credits {
    private let d = UserDefaults.standard
    var balance: Double? { d.object(forKey: "creditBalance") as? Double }
    var spent: Double { d.double(forKey: "creditSpent") }
    var calls: Int { d.integer(forKey: "creditCalls") }
    var exhausted: Bool { d.bool(forKey: "creditExhausted") }
    // $ per 1M tokens. Decisions bills uncached input at $0.10 and doesn't charge output. The cache-read
    // rate isn't stated; 90% off is assumed.
    var inputPrice: Double { d.object(forKey: "priceInput") as? Double ?? 0.10 }
    var cachedPrice: Double { d.object(forKey: "priceCached") as? Double ?? 0.01 }

    var remaining: Double? { exhausted ? 0 : balance.map { max(0, $0 - spent) } }

    func record(_ r: DecisionResult) {
        if r.errorCode == "insufficient_quota" || r.errorCode == "credit_balance_exhausted" {
            d.set(true, forKey: "creditExhausted"); return
        }
        guard r.error == nil else { return }
        d.set(false, forKey: "creditExhausted")
        let cost = Double(r.inputTokens - r.cachedTokens) * inputPrice / 1e6 + Double(r.cachedTokens) * cachedPrice / 1e6
        d.set(spent + cost, forKey: "creditSpent")
        d.set(calls + 1, forKey: "creditCalls")
    }

    func setBalance(_ v: Double) {
        d.set(v, forKey: "creditBalance"); d.set(0.0, forKey: "creditSpent"); d.set(0, forKey: "creditCalls")
        d.set(false, forKey: "creditExhausted")
    }

    static func money(_ v: Double) -> String { v < 0.01 && v > 0 ? String(format: "$%.4f", v) : String(format: "$%.2f", v) }

    /// Short text for the menu bar.
    var title: String {
        if let r = remaining { return Credits.money(r) }
        return calls > 0 ? "\(Credits.money(spent)) used" : "Set $"
    }

    var detail: String {
        let avg = calls > 0 ? " · avg \(Credits.money(spent / Double(calls)))/command" : ""
        if exhausted { return "Out of credits — add credits at platform.openai.com" }
        if let b = balance { return "\(Credits.money(remaining ?? 0)) left of \(Credits.money(b)) · \(calls) commands\(avg)" }
        return "\(Credits.money(spent)) spent · \(calls) commands\(avg)"
    }
}

final class DecisionClient {
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c)
    }()
    private let endpoint = URL(string: "https://api.openai.com/v1/decisions")!
    let key: String
    init(key: String) { self.key = key }

    /// Opens the TLS connection while the user is still talking, so the real request reuses it.
    func warmUp() {
        var r = URLRequest(url: endpoint); r.httpMethod = "HEAD"
        session.dataTask(with: r).resume()
    }

    /// The question wording, shared with the local fallback. The chained form tested best: each step right,
    /// "none" when there are fewer parts.
    static func instructions(step i: Int, of steps: Int, catalog: Bool) -> String {
        let nth = ["first", "second", "third", "fourth", "fifth"][min(i, 5) - 1]
        let what = steps == 1
            ? "Pick the single action they meant."
            : "Split what they said into separate actions, in the order they said them (joined by words like 'and', 'then', or commas). Which action matches the \(nth) part? If there is no \(nth) part, pick \"none\"."
        return "The user spoke a voice command to control their Mac. \(what) Speech recognition may mishear app names; match by sound and meaning."
            + (catalog ? " Values without a description are explained in the developer message." : "")
    }

    /// `steps` > 1 asks one question per position in a chained command ("open Safari and make a new tab").
    func decide(input: String, choices: [Choice], steps: Int = 1, completion: @escaping (DecisionResult) -> Void) {
        let catalogued = choices.filter(\.inCatalog)
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let choiceJSON: [[String: String]] = choices.map { $0.inCatalog ? ["value": $0.value] : ["value": $0.value, "description": $0.description] }
        let catalog = "Actions available on this Mac (value — meaning):\n" + catalogued.map { "\($0.value) — \($0.description)" }.joined(separator: "\n")
        let inputJSON: Any = catalogued.isEmpty ? input : [
            ["role": "developer", "content": [["type": "input_text", "text": catalog]]],
            ["role": "user", "content": [["type": "input_text", "text": input]]],
        ]
        let body: [String: Any] = [
            "model": "gpt-6-luna",
            "prompt_cache_key": "maccontrol",
            "input": inputJSON,
            "questions": (1...max(1, steps)).map { i -> [String: Any] in
                ["type": "choice", "name": "step\(i)", "choices": choiceJSON,
                 "instructions": DecisionClient.instructions(step: i, of: steps, catalog: !catalogued.isEmpty)]
            },
        ]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        try? r.httpBody?.write(to: logURL.deletingLastPathComponent().appendingPathComponent("MacControl-last-request.json"))
        let start = DispatchTime.now()
        session.dataTask(with: r) { data, resp, err in
            let ms = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if (resp as? HTTPURLResponse)?.statusCode != 200 { log("decision \(ms)ms status=\((resp as? HTTPURLResponse)?.statusCode ?? -1) \(raw.prefix(500))") }
            var result = DecisionResult(choice: nil, confidence: nil, ms: ms, error: err?.localizedDescription)
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let e = json["error"] as? [String: Any] {
                    result = DecisionResult(choice: nil, confidence: nil, ms: ms, error: e["message"] as? String ?? "API error")
                    result.errorCode = (e["code"] as? String) ?? (e["type"] as? String)
                } else if let answers = json["answers"] as? [[String: Any]], let a = answers.first {
                    if a["type"] as? String == "refusal" {
                        result = DecisionResult(choice: nil, confidence: nil, ms: ms, error: "refused")
                    } else {
                        result = DecisionResult(choice: a["choice"] as? String,
                                                confidence: (a["confidence"] as? NSNumber)?.doubleValue, ms: ms, error: nil)
                        result.alternatives = ((a["probabilities"] as? [[String: Any]]) ?? []).compactMap { p in
                            guard let v = p["value"] as? String, v != "none", let pr = (p["probability"] as? NSNumber)?.doubleValue else { return nil }
                            return (v, pr)
                        }.sorted { $0.probability > $1.probability }
                        result.steps = answers.compactMap { ans in
                            guard let c = ans["choice"] as? String, c != "none" else { return nil }
                            return (c, (ans["confidence"] as? NSNumber)?.doubleValue)
                        }
                    }
                }
                if let u = json["usage"] as? [String: Any] {
                    result.inputTokens = (u["input_tokens"] as? NSNumber)?.intValue ?? 0
                    result.outputTokens = (u["output_tokens"] as? NSNumber)?.intValue ?? 0
                    result.cachedTokens = ((u["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? NSNumber)?.intValue ?? 0
                }
            }
            let summary = result.steps.map { "\($0.choice) (\($0.confidence.map { String(format: "%.2f", $0) } ?? "?"))" }
            log("decided \(steps) step(s): \(summary.joined(separator: " → ")) tokens in=\(result.inputTokens) cached=\(result.cachedTokens) \(ms)ms")
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
