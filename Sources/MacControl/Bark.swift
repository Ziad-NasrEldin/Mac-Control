// Underdog Bark 3.0 Pro (Conway Research): an English fine-tune of Parakeet TDT 0.6B v3, used for typing mode.
import CoreML
import FluidAudio
import Foundation

/// The app doesn't download Bark: its Core ML folder from huggingface.co/ConwayResearch/Underdog-Bark-3.0-Pro is
/// expected at `~/Models/bark-3.0-pro/coreml` (where OpenSuperWhisper also reads it). Loading follows the model
/// card's Core ML runtime.
enum BarkModel {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Models/bark-3.0-pro/coreml", isDirectory: true)
    }

    /// The model was evaluated with 0.25 s of leading silence.
    static let leadingSilenceSamples = 4_000
    /// The encoder also ships an 8 s `short8` function; `full15` handles every length.
    private static let encoderFunction = "full15"
    private static let componentNames = ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"]
    private static let vocabularyName = "parakeet_v3_vocab.json"

    static var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent(vocabularyName).path) else { return false }
        return componentNames.allSatisfy { name in
            fm.fileExists(atPath: directory.appendingPathComponent(name + ".mlmodelc").path)
                || fm.fileExists(atPath: directory.appendingPathComponent(name + ".mlpackage").path)
        }
    }

    /// The encoder on the Neural Engine, the rest on the CPU, as the model card recommends.
    static func loadModels() throws -> AsrModels {
        let raw = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent(vocabularyName)))
        let vocabulary = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        return AsrModels(
            encoder: try load("Encoder", .cpuAndNeuralEngine, function: encoderFunction),
            preprocessor: try load("Preprocessor", .cpuOnly),
            decoder: try load("Decoder", .cpuOnly),
            joint: try load("JointDecisionv3", .cpuOnly),
            configuration: cpu,
            vocabulary: vocabulary,
            version: .ultra)
    }

    /// Prefers the compiled `.mlmodelc`; otherwise compiles the `.mlpackage` once and keeps it next to it.
    private static func load(_ name: String, _ units: MLComputeUnits, function: String? = nil) throws -> MLModel {
        let fm = FileManager.default
        let compiled = directory.appendingPathComponent(name + ".mlmodelc")
        let config = MLModelConfiguration()
        config.computeUnits = units
        // The encoder is a multifunction model; without a name Core ML loads its default function.
        if #available(macOS 15.0, *) { config.functionName = function }
        if !fm.fileExists(atPath: compiled.path) {
            let temp = try MLModel.compileModel(at: directory.appendingPathComponent(name + ".mlpackage"))
            do { try fm.moveItem(at: temp, to: compiled) } catch { return try MLModel(contentsOf: temp, configuration: config) }
        }
        return try MLModel(contentsOf: compiled, configuration: config)
    }
}
