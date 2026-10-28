import AppKit
import AVFoundation
import Speech
import ApplicationServices
import FluidAudio

// MARK: - Parakeet (local speech-to-text on the Neural Engine)

enum SpeechModel: String, CaseIterable, Identifiable {
    case english = "v2", multilingual = "v3"
    var id: String { rawValue }
    var title: String { self == .english ? "Parakeet v2 — English (most accurate)" : "Parakeet v3 — 25 European languages" }
    var version: AsrModelVersion { self == .english ? .v2 : .v3 }
}

final class ParakeetEngine {
    private var manager: AsrManager?
    private var loading: SpeechModel?
    private(set) var status = "Parakeet: loading…"
    var ready: Bool { manager != nil }
    var onStatus: ((String) -> Void)?
    var onReady: (() -> Void)?
    /// Silence put before every clip (Bark was evaluated with 0.25 s of it).
    private var leadingSilence = 0
    private var barkLoading = false

    /// Downloads the model (first use only, cached afterwards) and loads it onto the Neural Engine.
    func load(_ model: SpeechModel) {
        guard loading != model else { return }
        loading = model
        manager = nil
        setStatus("Parakeet: loading \(model == .english ? "v2" : "v3")…")
        Task {
            do {
                let start = Date()
                let models = try await AsrModels.downloadAndLoad(version: model.version)
                let m = AsrManager(config: .default)
                try await m.loadModels(models)
                // One silent pass so the first real command doesn't pay the compile/warm-up cost.
                var state = try TdtDecoderState()
                _ = try? await m.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
                await MainActor.run {
                    guard self.loading == model else { return }
                    self.manager = m
                    self.setStatus("Parakeet \(model == .english ? "v2" : "v3") ready (\(Int(Date().timeIntervalSince(start)))s load)")
                    self.onReady?()
                }
            } catch {
                log("parakeet load failed: \(error)")
                await MainActor.run { self.setStatus("Parakeet failed — using Apple speech") }
            }
        }
    }

    /// Loads Underdog Bark 3.0 Pro from its Core ML folder (see `BarkModel`) instead of a Parakeet release.
    func loadBark() {
        guard !barkLoading else { return }
        barkLoading = true
        leadingSilence = BarkModel.leadingSilenceSamples
        setStatus("Bark 3.0 Pro: loading…")
        Task {
            do {
                let start = Date()
                let models = try BarkModel.loadModels()
                let m = AsrManager(config: .default)
                try await m.loadModels(models)
                var state = try TdtDecoderState()
                _ = try? await m.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
                await MainActor.run {
                    guard self.barkLoading else { return }
                    self.manager = m
                    self.setStatus("Bark 3.0 Pro ready (\(Int(Date().timeIntervalSince(start)))s load)")
                    self.onReady?()
                }
            } catch {
                log("bark load failed: \(error)")
                await MainActor.run { self.barkLoading = false; self.setStatus("Bark 3.0 Pro failed to load — typing uses Parakeet") }
            }
        }
    }

    /// Frees the model (it holds over a gigabyte).
    func unload() {
        barkLoading = false; loading = nil; manager = nil
        setStatus("Off")
    }

    private func setStatus(_ s: String) { status = s; log(s); onStatus?(s) }

    /// `samples` must be 16 kHz mono Float. Calls back on main with text and processing ms.
    func transcribe(_ samples: [Float], completion: @escaping (String, Int) -> Void) {
        guard let manager else { completion("", 0); return }
        // Parakeet wants at least ~1 s of audio; pad short commands with silence.
        let lead = [Float](repeating: 0, count: leadingSilence) + samples
        let padded = lead.count < 16_000 ? lead + [Float](repeating: 0, count: 16_000 - lead.count) : lead
        Task {
            let start = DispatchTime.now()
            var result = ""
            do {
                var state = try TdtDecoderState()
                result = try await manager.transcribe(padded, decoderState: &state).text
            } catch { log("parakeet transcribe failed: \(error)") }
            let text = result
            let ms = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            await MainActor.run { completion(text.trimmingCharacters(in: .whitespacesAndNewlines), ms) }
        }
    }
}

// MARK: - Speech

/// Tells speech from quiet in 16 kHz audio, against a noise floor that follows the room, and says when a pause
/// after speech is long enough to end the utterance.
///
/// The floor is the quietest moment of the last two seconds: speech always dips between words, steady sound (a fan,
/// music, a hum) doesn't, so a room that gets louder — even mid-sentence — becomes the new quiet within two seconds.
struct SpeechGate {
    private(set) var voicedSamples = 0
    private(set) var silentRun = 0
    private(set) var noiseFloor: Float = 0.001
    /// Loudness smoothed over ~60 ms, so a room's flicker doesn't read as speech or break a pause.
    private(set) var level: Float = 0
    /// Recent smoothed levels with their block sizes, covering `window` samples.
    private var history: [(level: Float, count: Int)] = []
    private var historySamples = 0
    static let window = 32_000
    var speaking: Bool { voicedSamples >= Listener.minVoiced }

    mutating func push(_ s: [Float]) {
        guard !s.isEmpty else { return }
        var sum: Float = 0
        for x in s { sum += x * x }
        let rms = (sum / Float(s.count)).squareRoot()
        level = level * 0.7 + rms * 0.3
        history.append((level, s.count)); historySamples += s.count
        while historySamples - history[0].count >= SpeechGate.window { historySamples -= history.removeFirst().count }
        noiseFloor = max(0.0005, history.lazy.map(\.level).min() ?? level)
        // Starting to talk takes three times the room's own level; carrying on, twice. The absolute minimum only keeps
        // a dead-silent input from triggering on hiss.
        let loud = level > max(0.002, noiseFloor * (speaking ? 2 : 3))
        if loud {
            voicedSamples += s.count; silentRun = 0
        } else {
            silentRun += s.count
            // A click with nothing after it isn't the start of an utterance.
            if !speaking && silentRun > 16_000 { voicedSamples = 0 }
        }
    }

    /// Speech, then a pause of `seconds` — or, for a very long utterance, any quarter-second breath. `tooLong` closes
    /// it regardless (a room so loud it never sounds quiet).
    func ended(after seconds: Double, long: Bool, tooLong: Bool = false) -> Bool {
        speaking && (tooLong || silentRun >= Int(seconds * 16_000) || (long && silentRun >= 4_000))
    }

    mutating func reset() { voicedSamples = 0; silentRun = 0 }
}

final class Listener {
    let parakeet = ParakeetEngine()
    /// Makes the final transcripts (at each pause and on release) when set — Bark for typing mode. Live transcripts
    /// stay on `parakeet`, which is faster.
    var finalEngine: ParakeetEngine?
    private var finals: ParakeetEngine { finalEngine.flatMap { $0.ready ? $0 : nil } ?? parakeet }
    private let converter = AudioConverter()
    private var samples16k: [Float] = []
    private var usingParakeet = false
    private(set) var lastSttMs: Int?
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var best = ""
    private var finished: ((String) -> Void)?
    private var useOnDevice = true
    private var generation = 0
    // Audio captured this press, kept so it can be replayed into server recognition if on-device fails.
    private var captured: [AVAudioPCMBuffer] = []
    private var peak: Float = 0
    // State shared with the audio thread.
    private let liveLock = NSLock()
    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private var active = false
    private var ring: [Float] = []
    private var firstBufferAt: Date?

    /// Keeps the mic open between commands and prepends the last half second, so the first word isn't clipped.
    private(set) var alwaysOn = false
    let preRollSamples = 8_000
    private var startedAt = Date()
    /// Time from key press to the first audio buffer (0 when the mic was already open).
    private(set) var micStartMs: Int?

    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// Live Parakeet transcript of the utterance so far, delivered every ~0.15 s while listening.
    var onStreamText: ((String) -> Void)?
    /// The final transcript of an utterance that ended on a pause; the mic keeps listening for the next one.
    var onUtterance: ((String) -> Void)?
    private var streamTimer: Timer?
    private var streamBusy = false
    private var streamedSamples = 0

    // End of speech (Parakeet only): a pause after speech closes the utterance, so nobody has to let go.
    /// Audio-thread state, under `liveLock`.
    private var gate = SpeechGate()
    /// Bumped at each pause, so live passes still running on the previous utterance are dropped.
    private var segment = 0
    /// The previous utterance's final transcript is still being made; the next one waits for it, in order.
    private var awaitingFinal = false
    private var afterFinal: (() -> Void)?
    /// Utterances closed by a pause during this listening session.
    private(set) var utterances = 0
    /// A pause this long after speech ends an utterance.
    var endpointSeconds = 0.7
    /// Less than 0.1 s above the noise is a click or a breath, not speech.
    static let minVoiced = 1_600
    /// Past 15 s without a full pause, a quarter-second breath is enough to close the utterance (keeps passes fast);
    /// at 25 s it's closed anyway.
    static let maxUtteranceSamples = 16_000 * 15
    /// Hands-free: drop audio before speech starts. Off while the key is held, so a quiet voice the gate doesn't
    /// count as speech is still all transcribed on release.
    var dropsSilence = false
    var hints: [String] = []
    /// Why the last attempt produced no text, for the overlay.
    private(set) var lastProblem: String?

    var isEngineRunning: Bool { engine.isRunning }
    var preRollCount: Int { liveLock.lock(); defer { liveLock.unlock() }; return ring.count }
    /// The room's measured level, for logs and self-tests.
    var noiseFloor: Float { liveLock.lock(); defer { liveLock.unlock() }; return gate.noiseFloor }
    var gateState: String { liveLock.lock(); defer { liveLock.unlock() }; return "level \(gate.level) floor \(gate.noiseFloor) speaking \(gate.speaking) quiet \(gate.silentRun / 16) ms" }

    func setAlwaysOn(_ on: Bool) {
        alwaysOn = on
        liveLock.lock(); let busy = active; liveLock.unlock()
        guard !busy else { return }
        if on && parakeet.ready { openMic(parakeetMode: true, activate: false) }
        else if !on { stopEngine() }
        log("keep mic ready: \(on)")
    }

    /// Called when Parakeet finishes loading.
    func parakeetBecameReady() { if alwaysOn { setAlwaysOn(true) } }

    func start() {
        // Pressed again while the last release was waiting on a final transcript: finish that one first.
        if let pendingStop = afterFinal { afterFinal = nil; pendingStop() }
        best = ""; captured = []; peak = 0; lastProblem = nil; lastSttMs = nil; micStartMs = nil
        generation += 1
        utterances = 0; awaitingFinal = false; afterFinal = nil
        liveLock.lock(); gate = SpeechGate(); liveLock.unlock()
        startedAt = Date()
        usingParakeet = parakeet.ready
        if usingParakeet && alwaysOn && engine.isRunning {
            liveLock.lock(); samples16k = ring; ring = []; active = true; liveLock.unlock()
            micStartMs = 0
            startStreaming()
            return
        }
        if !usingParakeet {
            let auth = SFSpeechRecognizer.authorizationStatus()
            if auth != .authorized { lastProblem = "Speech recognition not allowed (status \(auth.rawValue))"; log(lastProblem!) }
        }
        openMic(parakeetMode: usingParakeet, activate: true)
        if !usingParakeet { _ = startRecognition(onDevice: useOnDevice && recognizer.supportsOnDeviceRecognition) }
        else { startStreaming() }
    }

    /// Re-transcribes the current utterance several times a second (Parakeet takes ~50 ms for a short clip), and
    /// closes the utterance when the speaker pauses. Only the audio since the last pause is ever re-run.
    private func startStreaming() {
        streamTimer?.invalidate()
        streamBusy = false; streamedSamples = 0
        let gen = generation
        streamTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, gen == self.generation, !self.awaitingFinal else { return }
            self.liveLock.lock()
            let isActive = self.active
            let ended = self.onUtterance != nil
                && self.gate.ended(after: self.endpointSeconds, long: self.samples16k.count >= Listener.maxUtteranceSamples,
                                   tooLong: self.samples16k.count >= Listener.maxUtteranceSamples * 5 / 3)
            var closed: [Float] = []
            if ended { closed = self.samples16k; self.samples16k = []; self.gate.reset() }
            let audio = self.samples16k
            self.liveLock.unlock()
            guard isActive else { return }
            if ended {
                self.segment += 1; self.streamedSamples = 0; self.utterances += 1
                self.awaitingFinal = true
                self.finals.transcribe(closed) { [weak self] text, ms in
                    guard let self else { return }
                    log("utterance ended on a pause: \"\(text)\" (\(ms) ms)")
                    // Delivered even if listening restarted meanwhile: it's what was said.
                    if gen == self.generation { self.awaitingFinal = false; self.lastSttMs = ms }
                    if !text.isEmpty { self.onUtterance?(text) }
                    if gen == self.generation, let next = self.afterFinal { self.afterFinal = nil; next() }
                }
                return
            }
            guard !self.streamBusy, self.onStreamText != nil else { return }
            // Wait for 0.4 s of audio, then re-run whenever there's 0.15 s more.
            guard audio.count >= 6_400, audio.count - self.streamedSamples >= 2_400 else { return }
            self.streamBusy = true
            self.streamedSamples = audio.count
            let seg = self.segment
            self.parakeet.transcribe(audio) { [weak self] text, _ in
                guard let self else { return }
                self.streamBusy = false
                self.liveLock.lock(); let stillOn = self.active; self.liveLock.unlock()
                guard gen == self.generation, seg == self.segment, stillOn, !text.isEmpty else { return }
                self.onStreamText?(text)
            }
        }
    }

    /// Under `liveLock`.
    private func trackSpeech(_ s: [Float]) {
        gate.push(s)
        // Before anyone speaks, keep only a short lead-in so the buffer doesn't grow during silence.
        if dropsSilence, !gate.speaking, samples16k.count > preRollSamples { samples16k.removeFirst(samples16k.count - preRollSamples) }
    }

    private func openMic(parakeetMode: Bool, activate: Bool) {
        stopEngine()
        liveLock.lock(); samples16k = []; ring = []; liveRequest = nil; active = activate; firstBufferAt = nil; liveLock.unlock()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            lastProblem = "No microphone input"; log("bad input format \(format)"); return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self else { return }
            let s = parakeetMode ? ((try? self.converter.resampleBuffer(buf)) ?? []) : []
            self.liveLock.lock()
            let isActive = self.active
            if parakeetMode {
                if isActive { self.samples16k += s; self.trackSpeech(s) }
                else { self.ring += s; if self.ring.count > self.preRollSamples { self.ring.removeFirst(self.ring.count - self.preRollSamples) } }
            } else {
                self.liveRequest?.append(buf)
            }
            let first = isActive && self.firstBufferAt == nil
            if first { self.firstBufferAt = Date() }
            self.liveLock.unlock()
            guard isActive else { return }
            let copy = parakeetMode ? nil : Listener.copy(buf)
            let p = Listener.peakLevel(buf)
            DispatchQueue.main.async {
                if let copy { self.captured.append(copy) }
                if first, self.micStartMs == nil { self.micStartMs = Int(Date().timeIntervalSince(self.startedAt) * 1000) }
                self.peak = max(self.peak, p)
                self.onLevel?(p)
            }
        }
        engine.prepare()
        do { try engine.start() } catch { lastProblem = "Microphone failed to start"; log("audio start failed: \(error)") }
    }

    private func startRecognition(onDevice: Bool) -> SFSpeechAudioBufferRecognitionRequest {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = onDevice
        req.taskHint = .search
        req.contextualStrings = Array(hints.prefix(100))
        request = req
        liveLock.lock(); liveRequest = req; liveLock.unlock()
        let gen = generation
        task = recognizer.recognitionTask(with: req) { [weak self] res, err in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                if let res { self.best = res.bestTranscription.formattedString; self.onPartial?(self.best) }
                if let err { self.failed(err, onDevice: onDevice) }
                else if res?.isFinal == true { self.deliver() }
            }
        }
        return req
    }

    private func failed(_ err: Error, onDevice: Bool) {
        let ns = err as NSError
        log("recognition error onDevice=\(onDevice) \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        guard best.isEmpty else { deliver(); return }
        // On-device model missing or Dictation off: fall back to Apple's server recognizer and replay what we heard.
        if onDevice {
            useOnDevice = false
            let req = startRecognition(onDevice: false)
            captured.forEach { req.append($0) }
            if !engine.isRunning { req.endAudio() }
            return
        }
        lastProblem = ns.localizedDescription
        deliver()
    }

    /// Stops listening; calls back with the final transcript (or the latest partial after a grace period).
    func stop(_ done: @escaping (String) -> Void) {
        streamTimer?.invalidate(); streamTimer = nil
        finished = done
        liveLock.lock(); active = false; let audio = samples16k; samples16k = []; let voiced = gate.voicedSamples; liveLock.unlock()
        if !(alwaysOn && usingParakeet) { stopEngine() }
        if usingParakeet {
            // The previous utterance's final transcript goes out first.
            if awaitingFinal { afterFinal = { [weak self] in self?.finishStop(audio, voiced: voiced) }; return }
            finishStop(audio, voiced: voiced)
            return
        }
        request?.endAudio()
        let gen = generation
        // Partial text usually exists already; only wait long when there's nothing yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, gen == self.generation, !self.best.isEmpty else { return }
            self.deliver()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.deliver()
        }
    }

    private func finishStop(_ audio: [Float], voiced: Int) {
        // Everything was already said and handled at a pause; only quiet is left.
        guard peak >= 0.002, utterances == 0 || voiced >= Listener.minVoiced else { deliver(); return }
        finals.transcribe(audio) { [weak self] text, ms in
            guard let self else { return }
            self.best = text; self.lastSttMs = ms
            self.deliver()
        }
    }

    /// Transcribes 16 kHz samples directly (self-tests).
    func transcribe(samples: [Float], completion: @escaping (String, Int) -> Void) { parakeet.transcribe(samples, completion: completion) }

    private func deliver() {
        guard let f = finished else { return }
        finished = nil
        task?.cancel(); task = nil; request = nil
        if best.isEmpty && lastProblem == nil {
            lastProblem = peak < 0.002 ? "Mic is silent — check Microphone permission / input device" : "No speech recognized"
        }
        log("heard \"\(best)\" peak=\(peak) mic-start=\(micStartMs.map { "\($0)ms" } ?? "?") engine=\(usingParakeet ? "parakeet \(lastSttMs ?? -1)ms" : "apple onDevice=\(useOnDevice)") problem=\(lastProblem ?? "-")")
        captured = []
        f(best)
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        c.frameLength = b.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: b.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(c.mutableAudioBufferList)
        for (s, d) in zip(src, dst) { if let sp = s.mData, let dp = d.mData { memcpy(dp, sp, Int(s.mDataByteSize)) } }
        return c
    }

    private static func peakLevel(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData?[0] else { return 1 }
        var p: Float = 0
        for i in 0..<Int(b.frameLength) { p = max(p, abs(ch[i])) }
        return p
    }
}
