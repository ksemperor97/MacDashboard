import Foundation
import Darwin

/// Owns exactly one log process group. EOF on stdin means its MacDashboard parent is gone.
/// This helper never searches for other processes or claims ownership based on their command.
enum LocalAILogHelper {
    static func run(executable: String) -> Int32 {
        // App installers may signal every process named MacDashboard, including this helper.
        // Let the owner's pipe close instead, so group cleanup still runs before we exit.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return 1 }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return 1 }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, STDOUT_FILENO)
        posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO)
        posix_spawnattr_setpgroup(&attributes, 0)
        var signals = sigset_t(0)
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)
        for signal in [SIGTERM, SIGINT, SIGPIPE, SIGHUP] { sigaddset(&signals, signal) }
        posix_spawnattr_setsigdefault(&attributes, &signals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([executable] + LMStudioLogObserver.arguments).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let error = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard error == 0 else { return 1 }
        defer {
            // The leader is still unreaped, so its PID/group ID cannot have been reused.
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
        while true {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid {
                return info.si_code == CLD_EXITED ? info.si_status : 1
            }
            var owner = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&owner, 1, 100)
            if ready < 0 && errno != EINTR { return 1 }
            if ready > 0 {
                if owner.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return 0 }
                if owner.revents & Int16(POLLIN) != 0 {
                    var byte: UInt8 = 0
                    if read(STDIN_FILENO, &byte, 1) <= 0 { return 0 }
                }
            }
        }
    }
}
