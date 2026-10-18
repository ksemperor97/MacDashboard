import Foundation
import Darwin

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

    /// Spawn a separate process group so a timeout also terminates pipe-holding children.
    /// All reads are nonblocking; completion never depends on pipe EOF after the deadline.
    /// Empty folder used as the working directory of every command the app runs.
    static let workingDirectory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDashboard/cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 30) async throws -> Data {
        let cancellation = CommandCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try execute(path, args, timeout: timeout, cancellation: cancellation))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func execute(_ path: String, _ args: [String], timeout: TimeInterval,
                                cancellation: CommandCancellation) throws -> Data {
        let name = (path as NSString).lastPathComponent
        let deadline = ProcessInfo.processInfo.systemUptime + max(timeout, 0)
        if cancellation.isCancelled { throw CancellationError() }
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { out.forEach { close($0) } }
        guard pipe(&err) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { err.forEach { close($0) } }
        for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        for fd in [out[0], err[0]] { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        // Run in an empty folder. CLIs such as agy treat the working directory as their workspace
        // and index it; from "/" (where Finder starts apps) that walks the whole disk and macOS
        // asks the user to let MacDashboard into Music, Photos, Documents and so on.
        posix_spawn_file_actions_addchdir(&actions, workingDirectory.path)
        posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
        for fd in out + err { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawnattr_setpgroup(&attributes, 0) // atomically create a group whose ID is the child's PID
        var signals = sigset_t(0)
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)
        for signal in [SIGTERM, SIGINT, SIGPIPE, SIGHUP] { sigaddset(&signals, signal) }
        posix_spawnattr_setsigdefault(&attributes, &signals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (searchPaths + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["NO_COLOR"] = "1"
        let argv = ([path] + args).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { argv in
            envp.withUnsafeBufferPointer { envp in
                posix_spawn(&pid, path, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        close(out[1]); out[1] = -1
        close(err[1]); err[1] = -1

        var stdout = Data(), stderr = Data()
        var outEOF = false, errEOF = false
        // Bound each drain so continuous output cannot starve the deadline/cancellation check.
        func drain(_ fd: Int32, into data: inout Data, eof: inout Bool) throws {
            guard !eof else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            for _ in 0..<8 {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
                else if count == 0 { eof = true; return }
                else if errno == EAGAIN || errno == EWOULDBLOCK { return }
                else if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }
        var reaped = false
        defer {
            if !reaped {
                // Kill before reaping: the unreaped leader reserves its PID/group identity.
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                let child = pid
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    while waitpid(child, &status, 0) < 0 && errno == EINTR {}
                }
            }
        }
        while true {
            if cancellation.isCancelled { throw CancellationError() }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw ShellError.timeout(name) }
            try drain(out[0], into: &stdout, eof: &outEOF)
            try drain(err[0], into: &stderr, eof: &errEOF)
            // Do not reap the leader while descendants still hold its pipes.
            if outEOF && errEOF {
                var status: Int32 = 0
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid {
                    reaped = true
                    let signal = status & 0x7f
                    let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
                    guard code == 0 else {
                        let message = String(decoding: stderr.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        throw ShellError.failed(name, code, String(message.prefix(200)))
                    }
                    return stdout
                }
                if waited < 0 && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD) }
            }
            usleep(10_000)
        }
    }
}

private final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
