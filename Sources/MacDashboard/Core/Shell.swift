import Foundation

enum ShellError: LocalizedError {
    case notFound(String)
    case timeout(String)
    case failed(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .notFound(let name): L.t("\(name) 실행 파일을 찾을 수 없어요", "\(name) executable not found")
        case .timeout(let name): L.t("\(name) 응답 시간 초과", "\(name) timed out")
        case .failed(let name, let code, let message): L.t("\(name) 실패", "\(name) failed") + " (\(code)) \(message)"
        }
    }
}

enum Shell {
    static let searchPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "/usr/bin", "/bin"]
    }()

    static func find(_ name: String) -> String? {
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in searchPaths + envPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Runs a command and returns stdout. Apps launched from Finder get a minimal PATH, so common
    /// tool directories are added (CLIs such as `claude` need `node` on PATH).
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 30) async throws -> Data {
        let name = (path as NSString).lastPathComponent
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
                env["NO_COLOR"] = "1"
                process.environment = env
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                var timedOut = false
                let timer = DispatchWorkItem {
                    timedOut = true
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                // Drain both pipes concurrently so a chatty stderr cannot block the child.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                timer.cancel()

                if timedOut {
                    cont.resume(throwing: ShellError.timeout(name))
                } else if process.terminationStatus != 0 {
                    let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    cont.resume(throwing: ShellError.failed(name, process.terminationStatus, String(message.prefix(200))))
                } else {
                    cont.resume(returning: outData)
                }
            }
        }
    }
}
