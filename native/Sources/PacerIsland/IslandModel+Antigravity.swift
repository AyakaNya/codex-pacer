import Foundation
import PacerCore
import PacerMacSupport

extension IslandModel {
    func refreshAntigravity(force: Bool = false) {
        guard isModuleEnabled(.antigravity), !demo, !sleeping, !stopped,
              ownedWork.task(.init(.activity, provider: .antigravity)) == nil,
              force || Date().timeIntervalSince(antigravityLastAttempt) >= 10 else { return }
        antigravityLastAttempt = Date(); antigravityRefreshing = true
        let reader = antigravityReader
        launchOwnedWork(.init(.activity, provider: .antigravity)) { [weak self] ticket in
            let reading = await reader.read(forceQuota: force)
            guard let self, self.lifecycle.owns(ticket), !Task.isCancelled, self.isModuleEnabled(.antigravity) else { return }
            self.ownedWork.finish(ticket)
            self.antigravityRefreshing = false
            self.antigravityConnected = reading.connected
            var status = RuntimeStreamStatus()
            status.connected = reading.connected; status.sourceAvailable = reading.connected
            status.attachedThreads = reading.activities.filter { [.running, .waitingForInput].contains($0.phase) }.count
            self.antigravityStreamStatus = status
            self.antigravityQuotaUnavailable = !reading.quotaAvailable
            self.antigravityQuota = reading.quota
            self.activityState.antigravityActivities = reading.activities
            self.activityState.antigravityReceivedRequests = reading.requests
            self.now = Date()
            self.refilterEmbeddedSessions()
        }
    }
    func makeAntigravityDemo(stage: DemoTaskStage) -> SessionActivity {
        let session = "019a0000-0000-7000-8000-000000000301"
        var value = SessionActivity(id: AgentProvider.antigravity.activityID(sessionID: session), project: "Demo · Antigravity",
            phaseAwareRate: true, provider: .antigravity, sessionID: session)
        func event(_ method: String, _ fields: [String: Any] = [:]) -> [String: Any] {
            ["method": method, "threadId": session, "turnId": "demo-turn", "at": now.timeIntervalSince1970 - 0.001]
                .merging(fields) { _, new in new }
        }
        value.applyRuntime(event("turn/attached", ["startedAt": now.addingTimeInterval(-30).timeIntervalSince1970]))
        value.applyRuntime(event("metadata", ["name": "Demo · Antigravity", "model": "gemini-3.1-pro"]))
        value.applyRuntime(event("item/started", ["itemId": "demo-step", "itemType": stage == .tool ? "commandExecution" : stage == .responding ? "agentMessage" : "reasoning"]))
        if stage == .completed { value.applyRuntime(event("turn/completed", ["status": "completed"])) }
        let reset = now.addingTimeInterval(7200).timeIntervalSince1970
        antigravityQuota = try? AntigravityAdapter.quota(Data("""
        {"groups":[{"displayName":"Gemini","buckets":[
        {"bucketId":"gemini-5h","remainingFraction":0.86,"resetTime":\(reset)},
        {"bucketId":"gemini-weekly","remainingFraction":0.55,"resetTime":\(reset + 86400)}]},
        {"displayName":"Claude + GPT","buckets":[
        {"bucketId":"3p-5h","remainingFraction":0.73,"resetTime":\(reset)},
        {"bucketId":"3p-weekly","remainingFraction":0.64,"resetTime":\(reset + 172800)}]}]}
        """.utf8), now: now)
        return value
    }
    func resetAntigravitySource() {
        cancelOwnedWork(.init(.activity, provider: .antigravity))
        antigravityReader = MacAntigravityReader()
        antigravityQuota = nil; antigravityRefreshing = false; antigravityConnected = false; antigravityStreamStatus = RuntimeStreamStatus()
        antigravityQuotaUnavailable = false; antigravityLastAttempt = .distantPast
        activityState.antigravityActivities = []; activityState.antigravityReceivedRequests = []
        activityState.antigravityAttention = AttentionPolicy()
        completionInbox.remove(provider: .antigravity)
        bindCompletionSources(.antigravity)
        refilterEmbeddedSessions()
        refreshAntigravity(force: true)
    }
}
