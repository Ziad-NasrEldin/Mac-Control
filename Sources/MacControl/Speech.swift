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

    private func setStatus(_ s: String) { status = s; log(s); onStatus?(s) }

    /// `samples` must be 16 kHz mono Float. Calls back on main with text and processing ms.
    func transcribe(_ samples: [Float], completion: @escaping (String, Int) -> Void) {
        guard let manager else { completion("", 0); return }
        // Parakeet wants at least ~1 s of audio; pad short commands with silence.
        let padded = samples.count < 16_000 ? samples + [Float](repeating: 0, count: 16_000 - samples.count) : samples
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

final class Listener {
    let parakeet = ParakeetEngine()
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
    /// Live Parakeet transcript of everything said so far, delivered every ~0.35 s while the key is held.
    var onStreamText: ((String) -> Void)?
    private var streamTimer: Timer?
    private var streamBusy = false
    private var streamedSamples = 0
    var hints: [String] = []
    /// Why the last attempt produced no text, for the overlay.
    private(set) var lastProblem: String?

    var isEngineRunning: Bool { engine.isRunning }
    var preRollCount: Int { liveLock.lock(); defer { liveLock.unlock() }; return ring.count }

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
        best = ""; captured = []; peak = 0; lastProblem = nil; lastSttMs = nil; micStartMs = nil
        generation += 1
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

    /// Re-transcribes the growing recording a few times a second (Parakeet takes ~50 ms for a short clip).
    private func startStreaming() {
        streamTimer?.invalidate()
        streamBusy = false; streamedSamples = 0
        let gen = generation
        streamTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self, gen == self.generation, !self.streamBusy, self.onStreamText != nil else { return }
            self.liveLock.lock(); let audio = self.samples16k; let isActive = self.active; self.liveLock.unlock()
            // Wait for half a second of audio, then only re-run once there's a quarter second more.
            guard isActive, audio.count >= 8_000, audio.count - self.streamedSamples >= 4_000 else { return }
            self.streamBusy = true
            self.streamedSamples = audio.count
            self.parakeet.transcribe(audio) { [weak self] text, _ in
                guard let self else { return }
                self.streamBusy = false
                self.liveLock.lock(); let stillHeld = self.active; self.liveLock.unlock()
                guard gen == self.generation, stillHeld, !text.isEmpty else { return }
                self.onStreamText?(text)
            }
        }
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
                if isActive { self.samples16k += s }
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
        liveLock.lock(); active = false; let audio = samples16k; samples16k = []; liveLock.unlock()
        if !(alwaysOn && usingParakeet) { stopEngine() }
        if usingParakeet {
            guard peak >= 0.002 else { deliver(); return }
            parakeet.transcribe(audio) { [weak self] text, ms in
                guard let self else { return }
                self.best = text; self.lastSttMs = ms
                self.deliver()
            }
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
