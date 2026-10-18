import Foundation

/// Local inference servers MacDashboard can talk to, on their default ports.
enum LocalEngineKind: String, Codable, CaseIterable, Identifiable {
    case lmStudio, ollama, llamaCpp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lmStudio: "LM Studio"
        case .ollama: "Ollama"
        case .llamaCpp: "llama.cpp"
        }
    }

    var baseURL: URL {
        switch self {
        case .lmStudio: URL(string: "http://127.0.0.1:1234")!
        case .ollama: URL(string: "http://127.0.0.1:11434")!
        case .llamaCpp: URL(string: "http://127.0.0.1:8080")!
        }
    }
}

/// A model currently loaded in the engine.
struct LocalModel: Identifiable, Equatable {
    let id: String                 // identifier used in API requests
    var name: String
    var format: String?            // MLX, GGUF, …
    var quantization: String?
    var architecture: String?
    var parameters: String?        // "27B"
    var sizeBytes: Int64?
    var contextLength: Int?        // loaded context
    var maxContextLength: Int?
    var parallel: Int?
    var state: String?             // idle / generating / loading
    var expiresAt: Date?           // auto-unload time, when the engine has one
}

struct LocalEngineStatus: Equatable {
    let kind: LocalEngineKind
    var version: String?
    var models: [LocalModel]
}

/// One measured request: either a benchmark run by MacDashboard or a request another app made
/// that the engine reported (LM Studio log stream).
struct SpeedSample: Identifiable, Codable, Equatable {
    enum Source: String, Codable { case benchmark, observed }

    var id = UUID()
    var date: Date
    var engine: LocalEngineKind
    var model: String
    var quantization: String?
    var source: Source
    var runID: UUID?               // benchmark runs group their steps
    var contextTokens: Int?        // target prompt size of a benchmark step
    var promptTokens: Int
    var completionTokens: Int
    var timeToFirstToken: Double?          // seconds
    var generationTokensPerSecond: Double?
    var promptTokensPerSecond: Double?
    var totalSeconds: Double?
}

struct BenchmarkProgress: Equatable {
    var step: Int
    var total: Int
    var label: String
}

enum LocalAIError: LocalizedError {
    case noModel
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .noModel: L.t("로드된 모델이 없어요", "No model is loaded")
        case .badResponse(let engine): L.t("\(engine) 응답을 해석할 수 없어요", "Unexpected response from \(engine)")
        }
    }
}
