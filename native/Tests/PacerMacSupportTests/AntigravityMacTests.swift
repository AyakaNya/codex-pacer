import Foundation
import XCTest
import PacerCore
@testable import PacerMacSupport

final class AntigravityMacTests: XCTestCase {
    func testAgyDiscoveryNeverExecutesTheCLI() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("antigravity-install-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let agy = bin.appendingPathComponent("agy")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: agy)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agy.path)
        let detection = ProviderInstallationDetection.detect(userHome: home, environment: [:],
            applicationURLs: Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map { ($0, []) }), systemBinDirectories: [])
        XCTAssertTrue(detection.antigravityInstalled)
        XCTAssertFalse(detection.codexInstalled)
    }
    func testLiveReadOnlyProbeWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["PACER_TEST_ANTIGRAVITY_LIVE"] == "1" else { throw XCTSkip("需明確啟用本機唯讀驗證") }
        let reading = await MacAntigravityReader().read(forceQuota: true)
        print("Antigravity: running=\(reading.activities.filter { $0.phase == .running }.count), waiting=\(reading.activities.filter { $0.phase == .waitingForInput }.count), unknown=\(reading.activities.filter { $0.phase == .unknown }.count)")
        print("Antigravity: models=\(reading.activities.filter { $0.modelName != nil }.count), knownCadences=\(reading.quota?.windows.filter { $0.durationMinutes != nil }.count ?? 0), resets=\(reading.quota?.windows.filter { $0.resetsAt != nil }.count ?? 0)")
        print("Antigravity: connected=\(reading.connected), tasks=\(reading.activities.count), quotaBuckets=\(reading.quota?.buckets.count ?? 0)")
        XCTAssertTrue(reading.connected, "沒有可讀取的已啟動 Language Server")
    }
}
