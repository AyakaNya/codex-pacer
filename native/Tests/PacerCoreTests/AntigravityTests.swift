import Foundation
import XCTest
@testable import PacerCore

final class AntigravityTests: XCTestCase {
    private let session = "019a0000-0000-7000-8000-000000000001"
    private let now = Date(timeIntervalSince1970: 1_800_000_100)
    private func trajectory(type: String = "PLANNER_RESPONSE", status: String = "RUNNING", stop: String? = nil,
                            running: Bool? = true, tools: Bool = false, suffix: String = "") throws -> AntigravityAdapter.Observation {
        let stopJSON = stop.map { "\"stopReason\":\"STOP_REASON_\($0)\"," } ?? ""
        let data = Data("""
        {"trajectory":{"cascadeId":"\(session)","steps":[
          {"type":"CORTEX_STEP_TYPE_USER_INPUT","metadata":{"createdAt":"2027-01-15T08:00:00Z"},"userInput":{"userResponse":"private prompt"}},
          {"type":"CORTEX_STEP_TYPE_\(type)","status":"CORTEX_STEP_STATUS_\(status)",
           "metadata":{"modelInfo":{"modelName":"gemini-3.1-pro"},"createdAt":"2027-01-15T08:00:01Z","completedAt":"2027-01-15T08:00:03Z"},
           "plannerResponse":{\(stopJSON)"toolCalls":\(tools ? "[{\"argumentsJson\":\"private tool arguments\"}]" : "[]"),"response":"private response"}}
          \(suffix)]}}
        """.utf8)
        return try AntigravityAdapter.trajectory(data, sessionID: session, title: "Sample", running: running, now: now)
    }
    func testTaskEvidenceRequiresLiveStatusAndExplicitEnding() throws {
        let thinking = try trajectory()
        XCTAssertEqual(thinking.phase, .running)
        XCTAssertEqual(thinking.stage, .responding)
        XCTAssertEqual(thinking.model, "gemini-3.1-pro")
        XCTAssertNotNil(thinking.startedAt)
        XCTAssertEqual(try trajectory(status: "DONE", running: false).phase, .unknown)
        XCTAssertEqual(try trajectory(running: nil).phase, .unknown)
        XCTAssertEqual(try trajectory(type: "RUN_COMMAND", status: "ERROR", running: false).phase, .unknown)
        XCTAssertEqual(try trajectory(status: "DONE", stop: "FUNCTION_CALL", running: false, tools: true).phase, .unknown)
        XCTAssertEqual(try trajectory(status: "DONE", stop: "STOP_PATTERN", running: false, tools: true).phase, .unknown)
        XCTAssertEqual(try trajectory(status: "DONE", stop: "STOP_PATTERN", running: false).phase, .completed)
        XCTAssertEqual(try trajectory(type: "FINISH", status: "DONE", running: false).phase, .completed)
        XCTAssertEqual(try trajectory(status: "DONE", stop: "STOP_PATTERN", running: true).phase, .running)
        XCTAssertEqual(try trajectory(type: "ASK_QUESTION", status: "WAITING").phase, .waitingForInput)
        XCTAssertTrue(try trajectory(type: "RUN_COMMAND", status: "WAITING").approval)
        XCTAssertTrue(try trajectory(status: "DONE", stop: "ERROR", running: false).failed)
        XCTAssertFalse(try trajectory(status: "DONE", stop: "CLIENT_CANCELED", running: false).failed)
    }
    func testDisconnectAndReplayNeverInventCompletionOrRepeatNotices() throws {
        var state = AntigravityActivityState(), app = ActivityApplicationState()
        state.consume(try trajectory(), sourceID: "agy")
        app.antigravityActivities = state.activities
        _ = app.reconcile(at: now, retention: 1800, visibility: .init())
        state.unavailable(sourceID: "agy")
        XCTAssertEqual(state.activities.first?.phase, .unknown)
        XCTAssertTrue(state.requests.isEmpty)
        app.antigravityActivities = state.activities
        XCTAssertTrue(app.reconcile(at: now, retention: 1800, visibility: .init()).notices.isEmpty)
        XCTAssertTrue(app.inbox.activities.isEmpty)
        state.consume(try trajectory(type: "ASK_QUESTION", status: "WAITING"), sourceID: "agy")
        var policy = AttentionPolicy()
        XCTAssertEqual(policy.requestNotices(state.requests).count, 1)
        XCTAssertTrue(policy.requestNotices(state.requests).isEmpty)
        state.unavailable(sourceID: "agy")
        _ = policy.requestNotices(state.requests)
        state.consume(try trajectory(type: "ASK_QUESTION", status: "WAITING"), sourceID: "agy")
        XCTAssertTrue(policy.requestNotices(state.requests).isEmpty)
        state.consume(try trajectory(status: "DONE", stop: "STOP_PATTERN", running: false), sourceID: "agy")
        app.antigravityActivities = state.activities
        let update = app.reconcile(at: now, retention: 1800, visibility: .init())
        XCTAssertEqual(update.activities.first?.provider, .antigravity)
        XCTAssertEqual(update.activities.first?.phase, .completed)
        XCTAssertNil(update.activities.first?.threadURL)
        XCTAssertEqual(app.inbox.activities.count, 1)
    }
    func testColdBaselineCompletionIsQuietAndProvidersStayIsolated() throws {
        var state = AntigravityActivityState()
        state.consume(try trajectory(status: "DONE", stop: "STOP_PATTERN", running: false), sourceID: "antigravity-ide")
        XCTAssertTrue(state.activities.first!.isHistoricalCompletion)
        var policy = AttentionPolicy()
        XCTAssertTrue(policy.activityNotices(state.activities, at: now).isEmpty)
        var modules = ProviderModules()
        let installed = ProviderInstallationDetection(codexInstalled: true, claudeInstalled: true, deepseekInstalled: true, antigravityInstalled: true)
        XCTAssertEqual(modules.enabledProviders(detection: installed), Set(AgentProvider.allCases))
        modules.setMode(.disabled, for: .antigravity)
        XCTAssertEqual(modules.enabledProviders(detection: installed), [.codex, .claude, .deepseek])
        XCTAssertNotEqual(AgentProvider.codex.activityID(sessionID: session), state.activities.first?.id)
    }
    func testSummarySchemaAndUnrecognizedStatus() throws {
        let rows = try AntigravityAdapter.summaries(Data("""
        {"trajectorySummaries":{"\(session)":{"summary":"Sample","status":"CASCADE_RUN_STATUS_RUNNING"},"invalid":{}}}
        """.utf8))
        XCTAssertEqual(rows.count, 1); XCTAssertTrue(rows[0].running); XCTAssertFalse(rows[0].idle)
        XCTAssertTrue(try AntigravityAdapter.summaries(Data("{}".utf8)).isEmpty)
        XCTAssertThrowsError(try AntigravityAdapter.summaries(Data("{\"error\":\"private\"}".utf8)))
        XCTAssertThrowsError(try AntigravityAdapter.trajectory(Data("{\"trajectory\":{\"cascadeId\":\"other\",\"steps\":[]}}".utf8), sessionID: session))
    }
    func testQuotaBucketsPreserveFamilyCadenceUnknownAndReset() throws {
        let json = """
        {"response":{"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-5h","window":"5h","displayName":"5-hour","remaining":{"remainingFraction":0.91},"resetTime":"2027-01-15T12:00:00Z"},
            {"bucketId":"gemini-weekly","window":"weekly","remaining":{"remainingFraction":0.82},"resetTime":"1800010000"}]},
          {"displayName":"Claude + GPT","buckets":[
            {"bucketId":"3p-5h","remaining":{"case":"remainingFraction","value":0.73}},
            {"bucketId":"3p-weekly","remaining":{"remainingFraction":0.64}},
            {"bucketId":"3p-other","remaining":{"remainingFraction":0.99},"disabled":true},
            {"bucketId":"gemini-other","resetTime":"2027-01-15T12:00:00.123Z"},
            {"bucketId":"gemini-bad","remainingFraction":true},
            {"bucketId":"gemini-range","remainingFraction":1.01}]}]}}
        """
        let quota = try AntigravityAdapter.quota(Data(json.utf8), now: now)
        XCTAssertEqual(quota.buckets.count, 8)
        XCTAssertEqual(quota.windows.prefix(4).compactMap { $0.remainingPercent?.rounded() }, [91, 82, 73, 64])
        XCTAssertEqual(quota.windows.prefix(4).map(\.durationMinutes), [300, 10080, 300, 10080])
        XCTAssertEqual(Set(quota.windows.map(\.id)).count, 8)
        XCTAssertEqual(quota.buckets[2].name, "Claude + GPT · 3p-5h")
        XCTAssertTrue(quota.windows.suffix(4).allSatisfy { $0.usedPercent == nil })
        XCTAssertNotNil(quota.windows[0].resetsAt); XCTAssertNotNil(quota.windows[1].resetsAt); XCTAssertNotNil(quota.windows[5].resetsAt)
        XCTAssertThrowsError(try AntigravityAdapter.quota(Data("{\"response\":{\"groups\":[]}}".utf8)))
    }
    func testLegacyModelsKeepTheirOwnQuotaAndNeverInventCadence() throws {
        let q = try AntigravityAdapter.legacyQuota(Data("""
        {"userStatus":{"email":"private@example.invalid","cascadeModelConfigData":{"clientModelConfigs":[
        {"label":"Gemini Pro","modelOrAlias":{"model":"GEMINI_PRO"},"quotaInfo":{"remainingFraction":0.3,"resetTime":"2027-01-15T12:00:00Z"}},
        {"label":"Claude Opus","modelOrAlias":{"alias":"CLAUDE_OPUS"},"quotaInfo":{"resetTime":"2027-01-15T12:00:00Z"}}]}}}
        """.utf8), now: now)
        XCTAssertEqual(q.windows.count, 2)
        XCTAssertEqual(q.windows[0].remainingPercent, 30)
        XCTAssertNil(q.windows[1].remainingPercent)
        XCTAssertTrue(q.windows.allSatisfy { $0.durationMinutes == nil })
        XCTAssertNil(q.accountScope)
    }
    func testGeneratorModelIsScopedToTheCurrentUserTurn() throws {
        let json = """
        {"trajectory":{"cascadeId":"\(session)","steps":[
        {"type":"CORTEX_STEP_TYPE_USER_INPUT","metadata":{"createdAt":"2027-01-15T08:00:00Z"}},
        {"type":"CORTEX_STEP_TYPE_PLANNER_RESPONSE","status":"CORTEX_STEP_STATUS_DONE"},
        {"type":"CORTEX_STEP_TYPE_USER_INPUT","metadata":{"createdAt":"2027-01-15T08:01:00Z"}},
        {"type":"CORTEX_STEP_TYPE_NOTIFY_USER","status":"CORTEX_STEP_STATUS_DONE","notifyUser":{"isBlocking":true}}],
        "generatorMetadata":[{"stepIndices":[1],"chatModel":{"responseModel":"old-model","systemPrompt":"private"}},
        {"stepIndices":[3],"chatModel":{"responseModel":"gemini-3.1-pro","messagePrompts":["private"]}}]}}
        """
        let value = try AntigravityAdapter.trajectory(Data(json.utf8), sessionID: session, running: false, now: now)
        XCTAssertEqual(value.model, "gemini-3.1-pro")
        XCTAssertEqual(value.phase, .waitingForInput)
        XCTAssertFalse(value.approval)
        XCTAssertFalse(String(describing: value).contains("private"))
        let noCurrentModel = json.replacingOccurrences(of: "\"stepIndices\":[3]", with: "\"stepIndices\":[1]")
        XCTAssertNil(try AntigravityAdapter.trajectory(Data(noCurrentModel.utf8), sessionID: session, running: false, now: now).model)
    }
    func testQuotaErrorEnvelopeAndDuplicateBucketAreRejected() {
        XCTAssertThrowsError(try AntigravityAdapter.quota(Data("""
        {"code":16,"response":{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":1}]}]}}
        """.utf8)))
        XCTAssertThrowsError(try AntigravityAdapter.quota(Data("""
        {"groups":[{"buckets":[{"bucketId":"gemini-5h"},{"bucketId":"gemini-5h"}]}]}
        """.utf8)))
    }

}
