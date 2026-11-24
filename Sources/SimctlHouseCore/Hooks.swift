import Foundation

/// Why a device is being prepared; the hook sees it as `$SIMCTLHOUSE_PREPARE_REASON`.
public enum PrepareReason: String, Sendable {
    /// Created for `acquire`, `run` or `create`.
    case create
    /// Re-created under a new name after its lease expired or was abandoned.
    case recreate
    /// Wiped in place by `erase`.
    case erase
}

/// A device that just came out of `simctl create` or `simctl erase`: shut down, and claimed by this process.
public struct PreparedDevice: Equatable, Sendable {
    public var udid: String
    public var name: String
    public var deviceTypeIdentifier: String
    public var runtimeIdentifier: String
    public var reason: PrepareReason

    /// What the hook finds in its environment. The same names `run` uses for the device, so one script serves both.
    var environment: [String: String] {
        [
            "SIMCTLHOUSE_UDID": udid,
            "SIMCTLHOUSE_DEVICE_NAME": name,
            "SIMCTLHOUSE_DEVICE_TYPE": deviceTypeIdentifier,
            "SIMCTLHOUSE_RUNTIME": runtimeIdentifier,
            "SIMCTLHOUSE_PREPARE_REASON": reason.rawValue,
        ]
    }
}

/// Runs the prepare hook. The seam that keeps `PoolTests` free of real processes.
public protocol DeviceHooks: Sendable {
    /// Returns once the hook succeeded; throws `SimctlHouseError.prepareFailed` otherwise.
    func prepare(_ device: PreparedDevice, with hook: PrepareHook) throws
}

/// Runs the hook with `/bin/sh -c`, with this process's environment plus the device's.
///
/// Its stdout and stderr both go to this process's stderr, which is the daemon's log in the daemon, so the hook never
/// writes into the UDID or JSON a command prints. It gets no stdin, since it may run where no one can answer.
/// It stays in this process's group, so a Ctrl-C that ends the command ends the hook too.
public struct ShellHooks: DeviceHooks {
    /// How long a hook that outlived its timeout gets to exit after SIGTERM before it is killed.
    static let terminationGrace: TimeInterval = 5

    let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func prepare(_ device: PreparedDevice, with hook: PrepareHook) throws {
        let pid = try spawn(hook.command, environment: environment.merging(device.environment) { _, device in device })
        let exited = DispatchSemaphore(value: 0)
        let status = Locked<Int32>(0)
        Thread.detachNewThread {
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1, errno == EINTR {}
            status.mutate { $0 = raw }
            exited.signal()
        }
        if exited.wait(timeout: .now() + hook.timeout) == .timedOut {
            // The shell and whatever it started, such as `simslim` and the `simctl` calls it makes.
            ProcessTable.signalTree(pid, SIGTERM)
            if exited.wait(timeout: .now() + Self.terminationGrace) == .timedOut {
                ProcessTable.signalTree(pid, SIGKILL)
                exited.wait()
            }
            throw SimctlHouseError.prepareFailed(device: device.name, detail: "did not finish within \(String(format: "%g", hook.timeout))s")
        }
        let raw = status.value
        // WIFEXITED / WEXITSTATUS / WTERMSIG, which Swift does not import.
        let signal = raw & 0x7f
        if signal != 0 { throw SimctlHouseError.prepareFailed(device: device.name, detail: "was killed by signal \(signal)") }
        let code = (raw >> 8) & 0xff
        if code != 0 { throw SimctlHouseError.prepareFailed(device: device.name, detail: "exited with status \(code)") }
    }

    private func spawn(_ command: String, environment: [String: String]) throws -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // The daemon ignores SIGTERM and SIGINT, and an ignored signal stays ignored across exec; the hook gets the defaults.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, 2, 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)

        // Typed first: Swift before 6.4 infers the literal's elements from `+ [nil]` and rejects the strings.
        let arguments: [String] = ["/bin/sh", "-c", command]
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
        guard result == 0 else { throw SimctlHouseError.io("Cannot start the prepare hook: \(String(cString: strerror(result)))") }
        return pid
    }
}
