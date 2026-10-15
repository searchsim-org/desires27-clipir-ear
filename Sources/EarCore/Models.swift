import Foundation

/// On-disk model locations (files from tools/models/sources.json; `make models` puts them in place).
/// Override with the environment variable CLIPIR_EAR_MODELS (tests, simulator scheme).
public enum Models {
    public static var directory: URL {
        if let env = ProcessInfo.processInfo.environment["CLIPIR_EAR_MODELS"] { return URL(fileURLWithPath: env) }
        #if os(macOS)
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/ClipIREar/models")
        #else
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(
                "models")
            #if targetEnvironment(simulator)
                // ponytail: the simulator can read the Mac's model folder directly (ADR-010); devices use Documents/models.
                if !FileManager.default.fileExists(atPath: docs.path),
                    let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"]
                {
                    return URL(fileURLWithPath: home).appendingPathComponent(
                        "Library/Application Support/ClipIREar/models")
                }
            #endif
            return docs
        #endif
    }

    public static func path(_ relative: String) throws -> String {
        let url = directory.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EarError.notFound("model file \(relative) (run `make models`)")
        }
        return url.path
    }

    public static let sileroVAD = "silero-vad/silero_vad_v5.onnx"
    public enum Zipformer {
        static let dir = "zipformer-en-2023-06-26/"
        public static let encoder = dir + "encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx"
        public static let decoder = dir + "decoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx"
        public static let joiner = dir + "joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx"
        public static let tokens = dir + "tokens.txt"
    }
    public static let nomicEmbed = "embed/nomic-embed-text-v1.5.Q8_0.gguf"
    public static let gemma4E2B = "llm/gemma-4-E2B-it-Q4_0.gguf"
    public static let qwen3Phone = "llm/Qwen3-1.7B-Q4_K_M.gguf"
    public static let qwen3CI = "llm/Qwen3-0.6B-Q8_0.gguf"
}
