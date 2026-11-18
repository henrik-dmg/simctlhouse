import Foundation

/// The command simctlhouse runs on every device that comes out of `simctl` in stock state:
/// created, re-created after a lease, or erased (D40).
public struct PrepareHook: Equatable, Sendable {
    public static let defaultTimeout: TimeInterval = 10 * 60
    /// Kept under `PoolConfig.hungOperation`, so a slow hook is stopped before GC judges its claim hung.
    public static let maximumTimeout: TimeInterval = 50 * 60

    /// Run by `/bin/sh -c`; the device comes in `$SIMCTLHOUSE_UDID` and friends.
    public var command: String
    public var timeout: TimeInterval

    public init(command: String, timeout: TimeInterval = PrepareHook.defaultTimeout) {
        self.command = command
        self.timeout = timeout
    }
}

/// Pool policy, from the environment over `<home>/config.json` over the defaults (D40).
public struct PoolConfig: Equatable, Sendable {
    public static let leaseVariable = "SIMCTLHOUSE_LEASE_SECONDS"
    public static let idleVariable = "SIMCTLHOUSE_IDLE_SECONDS"
    public static let daemonVariable = "SIMCTLHOUSE_DAEMON"
    public static let prepareVariable = "SIMCTLHOUSE_PREPARE"

    /// A lease not released or renewed within this window is forcefully reclaimed.
    public var leaseDuration: TimeInterval = 30 * 60
    /// Free booted devices are shut down after this much inactivity; 0 shuts them down on the next command.
    /// The `gc` command shuts them down regardless.
    public var idleShutdown: TimeInterval = 15 * 60
    /// A `provisioning` / `maintenance` step is repaired as soon as the process running it is gone.
    /// One still running after this long is presumed hung and repaired too; its claim keeps it from acting afterwards.
    public var hungOperation: TimeInterval = 60 * 60
    /// `delete` and `erase` wait this long for a device that is `provisioning` or `maintenance`, such as one the daemon is shutting down.
    public var busyWait: TimeInterval = 30
    /// Whether `acquire`, `release`, `renew` and `run` start the daemon.
    public var startsDaemon = true
    public var prepare: PrepareHook? = nil

    public init() {}

    /// Reads `<home>/config.json` and the environment of this process.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> PoolConfig {
        try load(environment: environment, file: HousePaths.fromEnvironment(environment).configFile)
    }

    /// A malformed value, in the file or the environment, is an error rather than silently ignored,
    /// so a typo cannot quietly leave an agent with a lease of the wrong length or a device that was never prepared.
    public static func load(environment: [String: String], file: URL) throws -> PoolConfig {
        try ConfigReport.load(environment: environment, file: file).config
    }
}

/// Where a setting's value came from.
public enum ConfigSource: String, Codable, Sendable {
    case `default`
    case file
    case environment
}

/// A setting's value as `config --json` prints it.
public enum ConfigValue: Equatable, Sendable, Encodable, CustomStringConvertible {
    case number(Double)
    case bool(Bool)
    case string(String)
    case none

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value) where value.rounded() == value && abs(value) < 1e15: try container.encode(Int64(value))
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .none: try container.encodeNil()
        }
    }

    public var description: String {
        switch self {
        case .number(let value) where value.rounded() == value && abs(value) < 1e15: String(Int64(value))
        case .number(let value): String(value)
        case .bool(let value): String(value)
        case .string(let value): value
        case .none: "none"
        }
    }
}

/// One setting of `simctlhouse config`.
public struct ConfigEntry: Equatable, Sendable, Encodable {
    /// The key path in `config.json`, e.g. `hooks.prepare.command`.
    public var key: String
    public var value: ConfigValue
    public var source: ConfigSource
    /// The environment variable that overrides it, if any.
    public var variable: String?
}

/// The effective configuration and where each value came from, for `simctlhouse config` and for `PoolConfig.load`.
public struct ConfigReport: Sendable, Encodable {
    public var file: String
    public var fileExists: Bool
    public var settings: [ConfigEntry]
    public var config: PoolConfig

    enum CodingKeys: String, CodingKey { case file, fileExists, settings }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ConfigReport {
        try load(environment: environment, file: HousePaths.fromEnvironment(environment).configFile)
    }

    public static func load(environment: [String: String], file: URL) throws -> ConfigReport {
        let parsed = try ConfigFile.read(file)
        var config = PoolConfig()
        var settings: [ConfigEntry] = []

        func seconds(_ key: String, _ variable: String, _ fromFile: Double?, allowZero: Bool, default value: TimeInterval) throws -> TimeInterval {
            let expected = allowZero ? "seconds, 0 or more" : "seconds, more than 0"
            var resolved = (value, ConfigSource.default)
            if let fromFile { resolved = (fromFile, .file) }
            if let raw = environment[variable], !raw.isEmpty {
                guard let parsed = TimeInterval(raw.trimmingCharacters(in: .whitespaces)), Self.isValid(parsed, allowZero: allowZero) else {
                    throw SimctlHouseError.invalidEnvironment(variable: variable, value: raw, expected: expected)
                }
                resolved = (parsed, .environment)
            }
            settings.append(ConfigEntry(key: key, value: .number(resolved.0), source: resolved.1, variable: variable))
            return resolved.0
        }

        config.leaseDuration = try seconds("leaseSeconds", PoolConfig.leaseVariable, parsed.leaseSeconds, allowZero: false, default: config.leaseDuration)
        config.idleShutdown = try seconds("idleSeconds", PoolConfig.idleVariable, parsed.idleSeconds, allowZero: true, default: config.idleShutdown)

        var daemon = (true, ConfigSource.default)
        if let fromFile = parsed.daemon { daemon = (fromFile, .file) }
        switch environment[PoolConfig.daemonVariable] {
        case nil, "": break
        case "1": daemon = (true, .environment)
        case "0": daemon = (false, .environment)
        case let value?: throw SimctlHouseError.invalidEnvironment(variable: PoolConfig.daemonVariable, value: value, expected: "0 or 1")
        }
        config.startsDaemon = daemon.0
        settings.append(ConfigEntry(key: "daemon", value: .bool(daemon.0), source: daemon.1, variable: PoolConfig.daemonVariable))

        // Unlike the other variables, an empty SIMCTLHOUSE_PREPARE means something: no hook, whatever the file says.
        var command = (parsed.prepareCommand, parsed.prepareCommand == nil ? ConfigSource.default : .file)
        if let raw = environment[PoolConfig.prepareVariable] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            command = (trimmed.isEmpty ? nil : raw, .environment)
        }
        let timeout = parsed.prepareTimeout ?? PrepareHook.defaultTimeout
        config.prepare = command.0.map { PrepareHook(command: $0, timeout: timeout) }
        settings.append(
            ConfigEntry(
                key: "hooks.prepare.command", value: command.0.map(ConfigValue.string) ?? .none, source: command.1, variable: PoolConfig.prepareVariable))
        settings.append(
            ConfigEntry(key: "hooks.prepare.timeoutSeconds", value: .number(timeout), source: parsed.prepareTimeout == nil ? .default : .file, variable: nil))

        return ConfigReport(file: file.path, fileExists: parsed.exists, settings: settings, config: config)
    }

    static func isValid(_ value: Double, allowZero: Bool) -> Bool {
        value.isFinite && (allowZero ? value >= 0 : value > 0)
    }
}

/// `<home>/config.json`, checked strictly: an unknown key is an error, so a misspelled setting never silently does nothing.
struct ConfigFile {
    var exists = false
    var leaseSeconds: Double?
    var idleSeconds: Double?
    var daemon: Bool?
    var prepareCommand: String?
    var prepareTimeout: Double?

    static func read(_ url: URL) throws -> ConfigFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return ConfigFile()
        } catch {
            throw SimctlHouseError.io("Cannot read \(url.path): \(error.localizedDescription)")
        }
        return try parse(data, path: url.path)
    }

    static func parse(_ data: Data, path: String) throws -> ConfigFile {
        func invalid(_ detail: String) -> SimctlHouseError { .invalidConfig(path: path, detail: detail) }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw invalid("not valid JSON (\((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription))")
        }

        func object(_ value: Any, _ key: String, allowed: [String]) throws -> [String: Any] {
            guard let object = value as? [String: Any] else { throw invalid("\(key) must be an object") }
            if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
                let path = key == "the file" ? unknown : "\(key).\(unknown)"
                throw invalid("\(path) is not a setting; known: \(allowed.joined(separator: ", "))")
            }
            return object
        }

        func seconds(_ value: Any?, _ key: String, allowZero: Bool, maximum: Double = .infinity) throws -> Double? {
            guard let value else { return nil }
            guard let number = value as? NSNumber, !Self.isBool(number), ConfigReport.isValid(number.doubleValue, allowZero: allowZero),
                number.doubleValue <= maximum
            else {
                let bound = maximum.isFinite ? ", at most \(Int(maximum))" : ""
                throw invalid("\(key) must be a number of seconds, \(allowZero ? "0 or more" : "more than 0")\(bound)")
            }
            return number.doubleValue
        }

        var file = ConfigFile(exists: true)
        let top = try object(root, "the file", allowed: ["leaseSeconds", "idleSeconds", "daemon", "hooks"])
        file.leaseSeconds = try seconds(top["leaseSeconds"], "leaseSeconds", allowZero: false)
        file.idleSeconds = try seconds(top["idleSeconds"], "idleSeconds", allowZero: true)
        if let daemon = top["daemon"] {
            guard let flag = daemon as? NSNumber, Self.isBool(flag) else { throw invalid("daemon must be true or false") }
            file.daemon = flag.boolValue
        }
        if let hooksValue = top["hooks"] {
            let hooks = try object(hooksValue, "hooks", allowed: ["prepare"])
            if let prepareValue = hooks["prepare"] {
                let prepare = try object(prepareValue, "hooks.prepare", allowed: ["command", "timeoutSeconds"])
                guard let command = prepare["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw invalid("hooks.prepare.command must be a non-empty shell command; remove hooks.prepare to run none")
                }
                file.prepareCommand = command
                file.prepareTimeout = try seconds(
                    prepare["timeoutSeconds"], "hooks.prepare.timeoutSeconds", allowZero: false, maximum: PrepareHook.maximumTimeout)
            }
        }
        return file
    }

    /// JSON `true` and `false` arrive as `NSNumber` too; only their type tells them from 1 and 0.
    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
