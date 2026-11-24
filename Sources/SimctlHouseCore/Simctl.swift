import Foundation

public struct SimDevice: Decodable, Equatable, Sendable {
    public var udid: String
    public var name: String
    public var state: String
    public var isAvailable: Bool
    public var deviceTypeIdentifier: String?

    public var isBooted: Bool { state == "Booted" }

    public init(udid: String, name: String, state: String, isAvailable: Bool = true, deviceTypeIdentifier: String? = nil) {
        self.udid = udid
        self.name = name
        self.state = state
        self.isAvailable = isAvailable
        self.deviceTypeIdentifier = deviceTypeIdentifier
    }
}

public struct SimDeviceType: Decodable, Equatable, Hashable, Sendable {
    public var identifier: String
    public var name: String
    public var productFamily: String?
    public var modelIdentifier: String?

    public init(identifier: String, name: String, productFamily: String?, modelIdentifier: String?) {
        self.identifier = identifier
        self.name = name
        self.productFamily = productFamily
        self.modelIdentifier = modelIdentifier
    }
}

public struct SimRuntime: Decodable, Equatable, Hashable, Sendable {
    public struct SupportedType: Decodable, Equatable, Hashable, Sendable {
        public var identifier: String
    }

    public var identifier: String
    public var name: String
    public var version: String
    public var platform: String?
    public var isAvailable: Bool
    public var supportedDeviceTypes: [SupportedType]

    public init(identifier: String, name: String, version: String, platform: String?, isAvailable: Bool = true, supportedDeviceTypes: [String]) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.platform = platform
        self.isAvailable = isAvailable
        self.supportedDeviceTypes = supportedDeviceTypes.map(SupportedType.init(identifier:))
    }
}

/// Everything simctlhouse needs from CoreSimulator. `Simctl` is the real implementation; tests use a fake.
public protocol SimulatorBackend: Sendable {
    func devices() throws -> [SimDevice]
    func deviceTypes() throws -> [SimDeviceType]
    func runtimes() throws -> [SimRuntime]
    func create(name: String, deviceType: String, runtime: String) throws -> String
    /// Boots the device if needed and blocks until it has finished booting.
    func bootAndWait(udid: String) throws
    func shutdown(udid: String) throws
    func delete(udid: String) throws
    /// Wipes contents and settings of a shut down device, keeping its UDID.
    func erase(udid: String) throws
    /// Whether the simulator still exists on disk. `devices()` can briefly leave out devices that exist,
    /// for example while CoreSimulator restarts, so a device is only taken for gone when this says so too (D23).
    func existsOnDisk(udid: String) -> Bool
    /// Disk space the simulator takes, in bytes, or nil if it cannot be measured.
    func diskUsage(udid: String) -> Int64?
    /// The booted simulator's SpringBoard's last exit status: non-zero once it has exited abnormally since the simulator
    /// booted (D41). Nil on a platform without SpringBoard; throws when the simulator does not answer.
    func springBoardExitStatus(udid: String) throws -> Int32?
}

public struct Simctl: SimulatorBackend {
    /// Runs `xcrun simctl` with the given arguments. Tests pass recorded output instead.
    let execute: @Sendable ([String], _ timeout: TimeInterval?) throws -> Subprocess.Result
    /// The default device set, where every pool device lives (D6): one directory per UDID.
    let devicesDirectory: URL

    public init() {
        self.init(execute: { arguments, timeout in try Subprocess.run("/usr/bin/xcrun", ["simctl"] + arguments, timeout: timeout) })
    }

    init(
        execute: @escaping @Sendable ([String], _ timeout: TimeInterval?) throws -> Subprocess.Result,
        devicesDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Developer/CoreSimulator/Devices")
    ) {
        self.execute = execute
        self.devicesDirectory = devicesDirectory
    }

    public func devices() throws -> [SimDevice] {
        struct Listing: Decodable { var devices: [String: [SimDevice]] }
        let data = try run(["list", "devices", "-j"])
        return try JSONDecoder().decode(Listing.self, from: data).devices.values.flatMap { $0 }
    }

    public func deviceTypes() throws -> [SimDeviceType] {
        struct Listing: Decodable { var devicetypes: [SimDeviceType] }
        return try JSONDecoder().decode(Listing.self, from: run(["list", "devicetypes", "-j"])).devicetypes
    }

    public func runtimes() throws -> [SimRuntime] {
        struct Listing: Decodable { var runtimes: [SimRuntime] }
        return try JSONDecoder().decode(Listing.self, from: run(["list", "runtimes", "-j"])).runtimes
    }

    public func create(name: String, deviceType: String, runtime: String) throws -> String {
        try runForUDID(["create", name, deviceType, runtime])
    }

    public func bootAndWait(udid: String) throws {
        _ = try run(["bootstatus", udid, "-b"])
    }

    public func shutdown(udid: String) throws {
        do {
            _ = try run(["shutdown", udid])
        } catch let error as SimctlHouseError {
            // Shutting down an already shut down device is not a failure for our purposes.
            if case .simctlFailed(_, _, let stderr) = error, stderr.contains("current state: Shutdown") { return }
            throw error
        }
    }

    public func erase(udid: String) throws {
        _ = try run(["erase", udid])
    }

    /// How long reading SpringBoard's status may take. It runs on every hand-out of a booted device, and a simulator that
    /// says it is booted but no longer answers would otherwise hold `acquire` forever (D41). Generous, since `simctl`
    /// calls take seconds when the machine is loaded, and a check that times out only skips the reboot.
    static let springBoardStatusTimeout: TimeInterval = 10

    /// Reads SpringBoard's last exit status from the simulator's launchd: `launchctl list` prints `PID STATUS LABEL`,
    /// and the status stays 0 until the job has exited abnormally; launchd then restarts it with a new PID.
    public func springBoardExitStatus(udid: String) throws -> Int32? {
        let data = try run(["spawn", udid, "launchctl", "list"], timeout: Self.springBoardStatusTimeout)
        return Self.springBoardExitStatus(inLaunchctlList: String(decoding: data, as: UTF8.self))
    }

    static func springBoardExitStatus(inLaunchctlList listing: String) -> Int32? {
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 3, fields[2] == "com.apple.SpringBoard" else { continue }
            return Int32(fields[1])
        }
        return nil
    }

    public func delete(udid: String) throws {
        _ = try run(["delete", udid])
    }

    /// Allocated size of the device's directory, which holds all of its data. Walks the tree, so call it for a few devices only.
    public func diskUsage(udid: String) -> Int64? {
        let directory = devicesDirectory.appending(path: udid)
        guard existsOnDisk(udid: udid),
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [])
        else { return nil }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// CoreSimulator keeps each device's configuration in `<UDID>/device.plist`; deleting the device removes the directory.
    public func existsOnDisk(udid: String) -> Bool {
        FileManager.default.fileExists(atPath: devicesDirectory.appending(path: udid).appending(path: "device.plist").path)
    }

    private func runForUDID(_ arguments: [String]) throws -> String {
        let output = String(decoding: try run(arguments), as: UTF8.self)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(_ arguments: [String], timeout: TimeInterval? = nil) throws -> Data {
        let result = try execute(arguments, timeout)
        guard result.status == 0 else {
            // simctl's own errors come from CoreSimulator; an `xcrun: error:` means simctl never ran.
            if result.stderr.hasPrefix("xcrun: error:") { throw SimctlHouseError.xcodeRequired(stderr: result.stderr) }
            throw SimctlHouseError.simctlFailed(command: (["simctl"] + arguments).joined(separator: " "), status: result.status, stderr: result.stderr)
        }
        return result.stdout
    }
}

enum Subprocess {
    struct Result {
        var status: Int32
        var stdout: Data
        var stderr: String
    }

    /// Runs the executable and waits for it to exit. A process still running after `timeout` is killed together with
    /// whatever it started, and `run` throws `SimctlHouseError.timedOut`.
    ///
    /// Output goes to temporary files rather than pipes. A process can hand its stdout on, as `simctl spawn` does to the
    /// one it starts in the simulator, and that one can hold a pipe open after the command was killed, so reading the
    /// pipe to its end would never return. A file also never fills up and stalls a chatty process.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = try scratchFile()
        let err = try scratchFile()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: timeout.map { .now() + $0 } ?? .distantFuture) == .timedOut {
            ProcessTable.signalTree(process.processIdentifier, SIGKILL)
            exited.wait()
            let command = ([(executable as NSString).lastPathComponent] + arguments).joined(separator: " ")
            throw SimctlHouseError.timedOut(command: command, seconds: timeout!)
        }
        return Result(status: process.terminationStatus, stdout: try contents(of: out), stderr: String(decoding: try contents(of: err), as: UTF8.self))
    }

    /// An open file that is already gone from the temporary directory, so nothing is left behind however the run ends.
    private static func scratchFile() throws -> FileHandle {
        var path = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("simctlhouse.XXXXXX").utf8CString)
        // Close-on-exec, so a process started at the same time on another thread does not inherit it.
        let descriptor = mkostemp(&path, O_CLOEXEC)
        guard descriptor != -1 else { throw SimctlHouseError.io("Cannot create a temporary file: \(String(cString: strerror(errno)))") }
        unlink(path)
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// The child wrote through a descriptor that shares this one's offset, so read from the start.
    private static func contents(of file: FileHandle) throws -> Data {
        try file.seek(toOffset: 0)
        return try file.readToEnd() ?? Data()
    }
}
