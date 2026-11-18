import Foundation
import Testing
@testable import SimctlHouseCore

@Suite final class PoolConfigTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "PoolConfigTests-\(UUID().uuidString)")
    var file: URL { root.appending(path: "config.json") }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func load(_ environment: [String: String] = [:]) throws -> PoolConfig {
        try PoolConfig.load(environment: environment, file: file)
    }

    private func write(_ json: String) throws {
        try json.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - environment

    @Test func defaultsWithoutFileOrVariables() throws {
        let config = try load()
        #expect(config.leaseDuration == 30 * 60)
        #expect(config.idleShutdown == 15 * 60)
        #expect(config.startsDaemon)
        #expect(config.prepare == nil)
    }

    @Test func readsSeconds() throws {
        let config = try load(["SIMCTLHOUSE_LEASE_SECONDS": "3600", "SIMCTLHOUSE_IDLE_SECONDS": " 0 "])
        #expect(config.leaseDuration == 3600)
        #expect(config.idleShutdown == 0)
    }

    @Test func emptyValueMeansDefault() throws {
        #expect(try load(["SIMCTLHOUSE_LEASE_SECONDS": ""]).leaseDuration == 30 * 60)
        #expect(try load(["SIMCTLHOUSE_DAEMON": ""]).startsDaemon)
    }

    @Test func theDaemonCanBeTurnedOff() throws {
        #expect(try load(["SIMCTLHOUSE_DAEMON": "1"]).startsDaemon)
        #expect(try !load(["SIMCTLHOUSE_DAEMON": "0"]).startsDaemon)
    }

    @Test(arguments: [
        ("SIMCTLHOUSE_LEASE_SECONDS", "0", "seconds, more than 0"),
        ("SIMCTLHOUSE_LEASE_SECONDS", "30m", "seconds, more than 0"),
        ("SIMCTLHOUSE_IDLE_SECONDS", "-1", "seconds, 0 or more"),
        ("SIMCTLHOUSE_IDLE_SECONDS", "inf", "seconds, 0 or more"),
        ("SIMCTLHOUSE_DAEMON", "no", "0 or 1"),
    ])
    func rejectsInvalidValues(variable: String, value: String, expected: String) {
        #expect(throws: SimctlHouseError.invalidEnvironment(variable: variable, value: value, expected: expected)) {
            try self.load([variable: value])
        }
    }

    // MARK: - config.json

    @Test func readsEverySettingFromTheFile() throws {
        try write(
            """
            {
              "leaseSeconds": 3600,
              "idleSeconds": 0,
              "daemon": false,
              "hooks": { "prepare": { "command": "echo \\"$SIMCTLHOUSE_UDID\\"", "timeoutSeconds": 120 } }
            }
            """)
        let config = try load()
        #expect(config.leaseDuration == 3600)
        #expect(config.idleShutdown == 0)
        #expect(!config.startsDaemon)
        #expect(config.prepare == PrepareHook(command: #"echo "$SIMCTLHOUSE_UDID""#, timeout: 120))
    }

    @Test func theHookTimeoutHasADefault() throws {
        try write(#"{ "hooks": { "prepare": { "command": "true" } } }"#)
        #expect(try load().prepare?.timeout == PrepareHook.defaultTimeout)
    }

    @Test func theEnvironmentWinsOverTheFile() throws {
        try write(#"{ "leaseSeconds": 3600, "daemon": false, "hooks": { "prepare": { "command": "from-file", "timeoutSeconds": 30 } } }"#)
        let config = try load(["SIMCTLHOUSE_LEASE_SECONDS": "60", "SIMCTLHOUSE_DAEMON": "1", "SIMCTLHOUSE_PREPARE": "from-env"])
        #expect(config.leaseDuration == 60)
        #expect(config.startsDaemon)
        // The timeout still comes from the file: it has no variable of its own.
        #expect(config.prepare == PrepareHook(command: "from-env", timeout: 30))
    }

    @Test func anEmptyPrepareVariableTurnsTheHookOff() throws {
        try write(#"{ "hooks": { "prepare": { "command": "echo \"$SIMCTLHOUSE_UDID\"" } } }"#)
        #expect(try load(["SIMCTLHOUSE_PREPARE": ""]).prepare == nil)
        #expect(try load(["SIMCTLHOUSE_PREPARE": "  "]).prepare == nil)
    }

    @Test func anEmptyFileObjectMeansDefaults() throws {
        try write("{}")
        #expect(try load() == PoolConfig())
    }

    @Test(arguments: [
        ("not json", "not valid JSON"),
        ("[]", "the file must be an object"),
        (#"{ "leaseSecond": 60 }"#, "leaseSecond is not a setting; known: leaseSeconds, idleSeconds, daemon, hooks"),
        (#"{ "leaseSeconds": 0 }"#, "leaseSeconds must be a number of seconds, more than 0"),
        (#"{ "leaseSeconds": "60" }"#, "leaseSeconds must be a number of seconds, more than 0"),
        (#"{ "leaseSeconds": true }"#, "leaseSeconds must be a number of seconds, more than 0"),
        (#"{ "idleSeconds": -1 }"#, "idleSeconds must be a number of seconds, 0 or more"),
        (#"{ "daemon": 0 }"#, "daemon must be true or false"),
        (#"{ "hooks": [] }"#, "hooks must be an object"),
        (#"{ "hooks": { "onCreate": {} } }"#, "hooks.onCreate is not a setting; known: prepare"),
        (#"{ "hooks": { "prepare": "echo" } }"#, "hooks.prepare must be an object"),
        (#"{ "hooks": { "prepare": { "comand": "x" } } }"#, "hooks.prepare.comand is not a setting; known: command, timeoutSeconds"),
        (#"{ "hooks": { "prepare": { "command": " " } } }"#, "hooks.prepare.command must be a non-empty shell command; remove hooks.prepare to run none"),
        (
            #"{ "hooks": { "prepare": { "command": "x", "timeoutSeconds": 3600 } } }"#,
            "hooks.prepare.timeoutSeconds must be a number of seconds, more than 0, at most 3000"
        ),
    ])
    func rejectsAnInvalidFile(json: String, detail: String) throws {
        try write(json)
        do {
            _ = try load()
            Issue.record("expected \(json) to be rejected")
        } catch let error as SimctlHouseError {
            guard case .invalidConfig(let path, let message) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(path == file.path)
            #expect(message.hasPrefix(detail))
            #expect(error.exitCode == 64)
        }
    }

    // MARK: - report

    @Test func theReportSaysWhereEachSettingComesFrom() throws {
        try write(#"{ "idleSeconds": 0, "hooks": { "prepare": { "command": "true" } } }"#)
        let report = try ConfigReport.load(environment: ["SIMCTLHOUSE_DAEMON": "0"], file: file)
        #expect(report.fileExists)
        #expect(
            report.settings == [
                ConfigEntry(key: "leaseSeconds", value: .number(1800), source: .default, variable: "SIMCTLHOUSE_LEASE_SECONDS"),
                ConfigEntry(key: "idleSeconds", value: .number(0), source: .file, variable: "SIMCTLHOUSE_IDLE_SECONDS"),
                ConfigEntry(key: "daemon", value: .bool(false), source: .environment, variable: "SIMCTLHOUSE_DAEMON"),
                ConfigEntry(key: "hooks.prepare.command", value: .string("true"), source: .file, variable: "SIMCTLHOUSE_PREPARE"),
                ConfigEntry(key: "hooks.prepare.timeoutSeconds", value: .number(600), source: .default, variable: nil),
            ])
    }

    @Test func theReportOfAMissingFileShowsNoHook() throws {
        let report = try ConfigReport.load(environment: [:], file: file)
        #expect(!report.fileExists)
        #expect(report.settings.first { $0.key == "hooks.prepare.command" }?.value == ConfigValue.none)
    }
}
