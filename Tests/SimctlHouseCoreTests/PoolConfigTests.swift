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
              "daemon": false
            }
            """)
        let config = try load()
        #expect(config.leaseDuration == 3600)
        #expect(config.idleShutdown == 0)
        #expect(!config.startsDaemon)
    }

    @Test func theEnvironmentWinsOverTheFile() throws {
        try write(#"{ "leaseSeconds": 3600, "daemon": false }"#)
        let config = try load(["SIMCTLHOUSE_LEASE_SECONDS": "60", "SIMCTLHOUSE_DAEMON": "1"])
        #expect(config.leaseDuration == 60)
        #expect(config.startsDaemon)
    }

    @Test func anEmptyFileObjectMeansDefaults() throws {
        try write("{}")
        #expect(try load() == PoolConfig())
    }

    @Test(arguments: [
        ("not json", "not valid JSON"),
        ("[]", "the file must be an object"),
        (#"{ "leaseSecond": 60 }"#, "leaseSecond is not a setting; known: leaseSeconds, idleSeconds, daemon"),
        (#"{ "leaseSeconds": 0 }"#, "leaseSeconds must be a number of seconds, more than 0"),
        (#"{ "leaseSeconds": "60" }"#, "leaseSeconds must be a number of seconds, more than 0"),
        (#"{ "leaseSeconds": true }"#, "leaseSeconds must be a number of seconds, more than 0"),
        (#"{ "idleSeconds": -1 }"#, "idleSeconds must be a number of seconds, 0 or more"),
        (#"{ "daemon": 0 }"#, "daemon must be true or false"),
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
        try write(#"{ "idleSeconds": 0 }"#)
        let report = try ConfigReport.load(environment: ["SIMCTLHOUSE_DAEMON": "0"], file: file)
        #expect(report.fileExists)
        #expect(
            report.settings == [
                ConfigEntry(key: "leaseSeconds", value: .number(1800), source: .default, variable: "SIMCTLHOUSE_LEASE_SECONDS"),
                ConfigEntry(key: "idleSeconds", value: .number(0), source: .file, variable: "SIMCTLHOUSE_IDLE_SECONDS"),
                ConfigEntry(key: "daemon", value: .bool(false), source: .environment, variable: "SIMCTLHOUSE_DAEMON"),
            ])
    }
}
