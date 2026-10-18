import Foundation

/// Talks to local inference servers over their own HTTP APIs. Each engine reports exact timings
/// for a request, so speeds come from the engine rather than from wall-clock guesses.
enum LocalEngines {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        return URLSession(configuration: config)
    }()

    private static let benchmarkSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 900   // long prompts on big models take minutes
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    // MARK: Detection

    /// The first engine that answers, preferring one with a loaded model.
    static func detect(detailed: Bool) async -> LocalEngineStatus? {
        var fallback: LocalEngineStatus?
        for kind in LocalEngineKind.allCases {
            guard let status = await status(of: kind, detailed: detailed) else { continue }
            if !status.models.isEmpty { return status }
            if fallback == nil { fallback = status }
        }
        return fallback
    }

    static func status(of kind: LocalEngineKind, detailed: Bool) async -> LocalEngineStatus? {
        switch kind {
        case .lmStudio: return await lmStudioStatus(detailed: detailed)
        case .ollama: return await ollamaStatus()
        case .llamaCpp: return await llamaCppStatus()
        }
    }

    private static func lmStudioStatus(detailed: Bool) async -> LocalEngineStatus? {
        guard let json = await getJSON(.lmStudio, "/api/v0/models") as? [String: Any],
              let data = json["data"] as? [[String: Any]] else { return nil }
        var models: [LocalModel] = data.filter { ($0["state"] as? String) == "loaded" && ($0["type"] as? String) != "embeddings" }
            .compactMap { m in
                guard let id = m["id"] as? String else { return nil }
                return LocalModel(id: id, name: id,
                                  format: (m["compatibility_type"] as? String)?.uppercased(),
                                  quantization: m["quantization"] as? String,
                                  architecture: m["arch"] as? String,
                                  contextLength: m["loaded_context_length"] as? Int,
                                  maxContextLength: m["max_context_length"] as? Int,
                                  state: "idle")
            }
        // `lms ps` adds size, parallel slots, live status and TTL. It costs ~0.25 s of CPU, so it is
        // only used while the Local AI popover is open.
        if detailed, let lms = lmsPath(),
           let out = try? await Shell.run(lms, ["ps", "--json"], timeout: 10),
           let list = (try? JSONSerialization.jsonObject(with: out)) as? [[String: Any]] {
            for item in list {
                guard let id = item["identifier"] as? String, let i = models.firstIndex(where: { $0.id == id }) else { continue }
                models[i].name = item["displayName"] as? String ?? models[i].name
                models[i].parameters = item["paramsString"] as? String
                models[i].sizeBytes = (item["sizeBytes"] as? NSNumber)?.int64Value
                models[i].parallel = item["parallel"] as? Int
                models[i].state = item["status"] as? String
                if let ttl = (item["ttlMs"] as? NSNumber)?.doubleValue, let last = (item["lastUsedTime"] as? NSNumber)?.doubleValue {
                    models[i].expiresAt = Date(timeIntervalSince1970: (last + ttl) / 1000)
                }
            }
        }
        return LocalEngineStatus(kind: .lmStudio, version: nil, models: models)
    }

    private static func ollamaStatus() async -> LocalEngineStatus? {
        guard let json = await getJSON(.ollama, "/api/ps") as? [String: Any] else { return nil }
        let version = (await getJSON(.ollama, "/api/version") as? [String: Any])?["version"] as? String
        let models: [LocalModel] = (json["models"] as? [[String: Any]] ?? []).compactMap { m in
            guard let name = m["name"] as? String ?? m["model"] as? String else { return nil }
            let details = m["details"] as? [String: Any]
            return LocalModel(id: name, name: name,
                              format: (details?["format"] as? String)?.uppercased(),
                              quantization: details?["quantization_level"] as? String,
                              architecture: details?["family"] as? String,
                              parameters: details?["parameter_size"] as? String,
                              sizeBytes: (m["size"] as? NSNumber)?.int64Value,
                              contextLength: m["context_length"] as? Int,
                              state: "loaded",
                              expiresAt: JSON.date(m["expires_at"]))
        }
        return LocalEngineStatus(kind: .ollama, version: version, models: models)
    }

    private static func llamaCppStatus() async -> LocalEngineStatus? {
        guard let props = await getJSON(.llamaCpp, "/props") as? [String: Any] else { return nil }
        let path = props["model_path"] as? String ?? "model"
        let settings = props["default_generation_settings"] as? [String: Any]
        let slots = await getJSON(.llamaCpp, "/slots") as? [[String: Any]]
        let busy = slots?.contains { ($0["is_processing"] as? Bool) == true } ?? false
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let model = LocalModel(id: name, name: name,
                               format: path.lowercased().hasSuffix(".gguf") ? "GGUF" : nil,
                               contextLength: (settings?["n_ctx"] as? Int) ?? (slots?.first?["n_ctx"] as? Int),
                               parallel: props["total_slots"] as? Int,
                               state: busy ? "generating" : "idle")
        return LocalEngineStatus(kind: .llamaCpp, version: props["build_info"] as? String, models: [model])
    }

    // MARK: Benchmark

    /// Sends one prompt and returns the engine's own timings for it.
    static func measure(_ kind: LocalEngineKind, model: LocalModel, prompt: String, maxTokens: Int) async throws -> SpeedSample {
        var sample = SpeedSample(date: Date(), engine: kind, model: model.name, quantization: model.quantization,
                                 source: .benchmark, promptTokens: 0, completionTokens: 0)
        switch kind {
        case .lmStudio:
            let json = try await postJSON(kind, "/api/v0/chat/completions", [
                "model": model.id, "stream": false, "max_tokens": maxTokens, "temperature": 0.7,
                "messages": [["role": "user", "content": prompt]],
            ])
            guard let stats = json["stats"] as? [String: Any], let usage = json["usage"] as? [String: Any]
            else { throw LocalAIError.badResponse(kind.displayName) }
            sample.promptTokens = usage["prompt_tokens"] as? Int ?? 0
            sample.completionTokens = usage["completion_tokens"] as? Int ?? 0
            sample.timeToFirstToken = JSON.double(stats["time_to_first_token"])
            sample.generationTokensPerSecond = JSON.double(stats["tokens_per_second"])
            sample.promptTokensPerSecond = LocalEngines.promptSpeed(tokens: sample.promptTokens, ttft: sample.timeToFirstToken)
            sample.totalSeconds = (sample.timeToFirstToken ?? 0) + (JSON.double(stats["generation_time"]) ?? 0)
        case .ollama:
            let json = try await postJSON(kind, "/api/chat", [
                "model": model.id, "stream": false,
                "messages": [["role": "user", "content": prompt]],
                "options": ["num_predict": maxTokens],
            ])
            func seconds(_ key: String) -> Double? { JSON.double(json[key]).map { $0 / 1e9 } }
            sample.promptTokens = json["prompt_eval_count"] as? Int ?? 0
            sample.completionTokens = json["eval_count"] as? Int ?? 0
            if let p = seconds("prompt_eval_duration"), p > 0 { sample.promptTokensPerSecond = Double(sample.promptTokens) / p }
            if let e = seconds("eval_duration"), e > 0 { sample.generationTokensPerSecond = Double(sample.completionTokens) / e }
            sample.timeToFirstToken = (seconds("load_duration") ?? 0) + (seconds("prompt_eval_duration") ?? 0)
            sample.totalSeconds = seconds("total_duration")
        case .llamaCpp:
            let json = try await postJSON(kind, "/completion", ["prompt": prompt, "n_predict": maxTokens, "cache_prompt": false])
            guard let t = json["timings"] as? [String: Any] else { throw LocalAIError.badResponse(kind.displayName) }
            sample.promptTokens = t["prompt_n"] as? Int ?? 0
            sample.completionTokens = t["predicted_n"] as? Int ?? 0
            sample.promptTokensPerSecond = JSON.double(t["prompt_per_second"])
            sample.generationTokensPerSecond = JSON.double(t["predicted_per_second"])
            sample.timeToFirstToken = JSON.double(t["prompt_ms"]).map { $0 / 1000 }
            sample.totalSeconds = ((JSON.double(t["prompt_ms"]) ?? 0) + (JSON.double(t["predicted_ms"]) ?? 0)) / 1000
        }
        return sample
    }

    /// A prompt of roughly `tokens` tokens. A random tag up front defeats prompt caching, so every
    /// run really processes the whole prompt.
    static func prompt(approximateTokens tokens: Int) -> String {
        let task = "Using the notes above only as filler, write a short paragraph about how tea spread around the world."
        guard tokens > 200 else { return "[\(UUID().uuidString)] Write a short paragraph about how tea spread around the world." }
        let sentence = "Note %d: the quick brown fox jumps over the lazy dog near the quiet river bank. "
        let count = max(tokens / 21, 1)   // each filler sentence is ~21 tokens (measured with Qwen's tokenizer)
        var text = "[\(UUID().uuidString)]\n"
        text.reserveCapacity(count * 80)
        for i in 1...count { text += String(format: sentence, i) }
        return text + "\n\n" + task
    }

    // MARK: Helpers

    /// LM Studio reports only time-to-first-token, which includes a fixed start-up cost; dividing a
    /// short prompt by it gives nonsense, so prompt speed is derived only for prompts of 500+ tokens.
    static func promptSpeed(tokens: Int, ttft: Double?) -> Double? {
        guard tokens >= 500, let ttft, ttft > 0 else { return nil }
        return Double(tokens) / ttft
    }

    static func lmsPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidate = "\(home)/.lmstudio/bin/lms"
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : Shell.find("lms")
    }

    private static func getJSON(_ kind: LocalEngineKind, _ path: String) async -> Any? {
        guard let url = URL(string: path, relativeTo: kind.baseURL),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func postJSON(_ kind: LocalEngineKind, _ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: path, relativeTo: kind.baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await benchmarkSession.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UsageError.http(code) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LocalAIError.badResponse(kind.displayName)
        }
        return json
    }
}
