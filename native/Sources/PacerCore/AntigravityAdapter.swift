import Foundation

/// Antigravity 的唯讀 RPC 投影；會話文字與工具參數不會被解碼。
public enum AntigravityAdapter {
    public struct Summary: Equatable, Sendable {
        public let id: String
        public let title: String?
        public let running: Bool
        public let idle: Bool
    }
    public struct Observation: Equatable, Sendable {
        public let sessionID: String
        public let turnID: String
        public let title: String?
        public let model: String?
        public let startedAt: Date?
        public let observedAt: Date
        public let phase: ActivityPhase
        public let stage: ActivityStage
        public let failed: Bool
        public let approval: Bool
        public let attentionID: String
    }
    public enum Failure: Error { case invalidResponse }

    public static func summaries(_ data: Data) throws -> [Summary] {
        let root = try JSONFieldView.document(data).fields(["trajectorySummaries"])
        guard let map = root["trajectorySummaries"] else {
            guard try JSONFieldView.document(data).fields().isEmpty else { throw Failure.invalidResponse }
            return []
        }
        var result: [Summary] = []
        try map.forEachField(maximumCount: 2048) { id, value in
            guard let id = AgentProvider.antigravity.validatedSessionID(id) else { return }
            let f = try value.fields(["summary", "status"])
            let status = f["status"]?.string()
            result.append(Summary(id: id, title: f["summary"]?.string(limit: 160),
                running: status == "CASCADE_RUN_STATUS_RUNNING" || status == "CASCADE_RUN_STATUS_BUSY", idle: status == "CASCADE_RUN_STATUS_IDLE"))
        }
        return result.sorted { $0.id < $1.id }
    }

    public static func trajectory(_ data: Data, sessionID: String, title: String? = nil,
                                  running: Bool? = nil, now: Date = Date()) throws -> Observation {
        let root = try JSONFieldView.document(data).fields(["trajectory"])
        guard let trajectory = root["trajectory"] else { throw Failure.invalidResponse }
        let f = try trajectory.fields(["cascadeId", "steps", "generatorMetadata"])
        guard f["cascadeId"]?.string() == sessionID, let steps = f["steps"] else { throw Failure.invalidResponse }
        var turn = "", start: Date?, model: String?, phase = ActivityPhase.unknown, stage = ActivityStage.starting
        var failed = false, approval = false
        var lastType = "", lastStatus = "", lastStop: String?, lastAt: Date?, toolCalls = 0
        var index = 0, turnStartIndex = 0
        try steps.forEachElement(maximumCount: 32768) { step in
            defer { index += 1 }
            let s = try step.fields(["type", "status", "metadata", "plannerResponse", "requestedInteraction", "notifyUser"])
            let type = s["type"]?.string() ?? "", status = s["status"]?.string() ?? ""
            let m = try s["metadata"]?.fields(["createdAt", "completedAt", "modelInfo", "generatorModel"]) ?? [:]
            let at = date(m["createdAt"]?.string())
            if type == "CORTEX_STEP_TYPE_USER_INPUT" {
                turn = String(index) + ":" + (m["createdAt"]?.string() ?? "undated")
                turnStartIndex = index
                start = at; model = nil; phase = .unknown; failed = false; approval = false
            }
            guard !turn.isEmpty else { return }
            if let info = m["modelInfo"], let name = try info.fields(["modelName"])["modelName"]?.string(limit: 128) {
                model = ModelDisplay.sanitizedModel(name)
            } else if let name = m["generatorModel"]?.string(limit: 128) { model = ModelDisplay.sanitizedModel(name) }
            let active = ["CORTEX_STEP_STATUS_GENERATING", "CORTEX_STEP_STATUS_RUNNING", "CORTEX_STEP_STATUS_QUEUED", "CORTEX_STEP_STATUS_PENDING"].contains(status)
            phase = active ? .running : .unknown
            stage = type == "CORTEX_STEP_TYPE_PLANNER_RESPONSE" ? .thinking : type == "CORTEX_STEP_TYPE_USER_INPUT" ? .starting : .tool
            approval = false; failed = false
            if status == "CORTEX_STEP_STATUS_WAITING" {
                phase = .waitingForInput
                approval = type != "CORTEX_STEP_TYPE_ASK_QUESTION" && type != "CORTEX_STEP_TYPE_NOTIFY_USER"
            }
            // 單一步驟錯誤可能會被模型修復，不能直接宣告整個任務失敗。
            if type == "CORTEX_STEP_TYPE_ERROR_MESSAGE", status == "CORTEX_STEP_STATUS_DONE" { phase = .interrupted; failed = true }
            if type == "CORTEX_STEP_TYPE_FINISH", status == "CORTEX_STEP_STATUS_DONE" { phase = .completed }
            let p = try s["plannerResponse"]?.fields(["stopReason", "toolCalls", "response"]) ?? [:]
            if type == "CORTEX_STEP_TYPE_PLANNER_RESPONSE", p["response"]?.hasNonemptyString == true { stage = .responding }
            if let interaction = s["requestedInteraction"], !interaction.isNull,
               !(try interaction.fields(maximumCount: 16)).isEmpty, status != "CORTEX_STEP_STATUS_DONE" {
                phase = .waitingForInput; approval = type != "CORTEX_STEP_TYPE_ASK_QUESTION"
            }
            if type == "CORTEX_STEP_TYPE_NOTIFY_USER", let notify = s["notifyUser"] {
                let n = try notify.fields(["isBlocking", "shouldAutoProceed"])
                if n["isBlocking"]?.boolean() == true, n["shouldAutoProceed"]?.boolean() != true {
                    phase = .waitingForInput; approval = false
                }
            }
            lastStop = p["stopReason"]?.string()
            toolCalls = try p["toolCalls"]?.countElements(maximumCount: 256) ?? 0
            lastType = type; lastStatus = status
            lastAt = date(m["completedAt"]?.string()) ?? at
        }
        guard !turn.isEmpty else { throw Failure.invalidResponse }
        if model == nil, let generators = f["generatorMetadata"], generators.isArray {
            var latestIndex = -1
            try generators.forEachElement(maximumCount: 32768) { generator in
                let g = try generator.fields(["stepIndices", "chatModel"])
                let indices = try g["stepIndices"]?.elements(maximumCount: 32768).compactMap { $0.integer() } ?? []
                guard let stepIndex = indices.filter({ $0 >= turnStartIndex && $0 < index }).max(), stepIndex > latestIndex,
                      let chat = g["chatModel"] else { return }
                let c = try chat.fields(["responseModel", "modelDisplayName", "model"])
                if let name = c["responseModel"]?.string(limit: 128) ?? c["modelDisplayName"]?.string(limit: 128) ?? c["model"]?.string(limit: 128) {
                    model = ModelDisplay.sanitizedModel(name); latestIndex = stepIndex
                }
            }
        }
        if running == nil, phase == .running || phase == .waitingForInput { phase = .unknown }
        if running == true, phase != .waitingForInput { phase = .running; failed = false }
        // 明確的生成終止原因與無後續工具呼叫才證明這一輪已結束。
        if running == false, lastType == "CORTEX_STEP_TYPE_PLANNER_RESPONSE", lastStatus == "CORTEX_STEP_STATUS_DONE", toolCalls == 0 {
            if lastStop == "STOP_REASON_STOP_PATTERN" { phase = .completed; stage = .responding }
            else if lastStop == "STOP_REASON_ERROR" { phase = .interrupted; failed = true }
            else if lastStop == "STOP_REASON_CLIENT_CANCELED" { phase = .interrupted }
        }
        return Observation(sessionID: sessionID, turnID: turn, title: title, model: model, startedAt: start,
            observedAt: [.completed, .interrupted].contains(phase) ? lastAt ?? now : now,
            phase: phase, stage: stage, failed: failed, approval: approval, attentionID: turn + ":" + String(index))
    }

    public static func quota(_ data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        let root = try JSONFieldView.document(data).fields(["response", "summary", "groups", "code"])
        if let code = root["code"], code.integer() != 0 && code.integer() != 200 { throw Failure.invalidResponse }
        let body = try (root["response"] ?? root["summary"])?.fields(["groups"]) ?? root
        guard let groups = body["groups"] else { throw Failure.invalidResponse }
        var buckets: [QuotaBucket] = [], seen: Set<String> = []
        try groups.forEachElement(maximumCount: 64) { group in
            let g = try group.fields(["displayName", "buckets"])
            guard let rows = g["buckets"] else { return }
            let groupName = g["displayName"]?.string(limit: 128)
            try rows.forEachElement(maximumCount: 128) { row in
                let r = try row.fields(["bucketId", "displayName", "remaining", "remainingFraction", "resetTime", "window", "disabled"])
                guard let id = r["bucketId"]?.string(limit: 128), !id.isEmpty, seen.insert(id).inserted else { throw Failure.invalidResponse }
                let remaining = try r["remaining"]?.fields(["remainingFraction", "case", "value"]) ?? [:]
                let fraction = r["remainingFraction"]?.number() ?? remaining["remainingFraction"]?.number() ??
                    (remaining["case"]?.string() == "remainingFraction" ? remaining["value"]?.number() : nil)
                let known = r["disabled"]?.boolean() != true && fraction.map { (0...1).contains($0) } == true
                let cadence = (r["window"]?.string() ?? id).lowercased().replacingOccurrences(of: "_", with: "-")
                let minutes: Int? = cadence.contains("weekly") || cadence == "7d" ? 10080 :
                    cadence.contains("5h") || cadence.contains("5-hour") || cadence.contains("five-hour") || cadence.contains("session") ? 300 : nil
                let family = id.hasPrefix("gemini-") ? "Gemini" : id.hasPrefix("3p-") ? "Claude + GPT" : groupName ?? "Antigravity"
                let name = r["displayName"]?.string(limit: 128) ?? id
                let reset = date(r["resetTime"]?.string()) ?? r["resetTime"]?.number().map { Date(timeIntervalSince1970: $0) }
                let window = QuotaWindow(id: id, usedPercent: known ? (1 - fraction!) * 100 : nil, durationMinutes: minutes, resetsAt: reset)
                buckets.append(QuotaBucket(id: id, name: family + " · " + name, plan: nil, windows: [window], credits: nil))
            }
        }
        guard !buckets.isEmpty else { throw Failure.invalidResponse }
        return QuotaSnapshot(buckets: buckets, capturedAt: now, accountScope: nil, resetCredits: nil)
    }

    public static func legacyQuota(_ data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        let root = try JSONFieldView.document(data).fields(["userStatus", "cascadeModelConfigData"])
        let status = try root["userStatus"]?.fields(["cascadeModelConfigData"]) ?? root
        guard let config = status["cascadeModelConfigData"],
              let models = try config.fields(["clientModelConfigs"])["clientModelConfigs"] else { throw Failure.invalidResponse }
        var buckets: [QuotaBucket] = [], seen: Set<String> = []
        try models.forEachElement(maximumCount: 256) { model in
            let f = try model.fields(["label", "modelOrAlias", "quotaInfo"])
            guard let quota = f["quotaInfo"] else { return }
            let identity = try f["modelOrAlias"]?.fields(["model", "alias"]) ?? [:]
            guard let id = identity["model"]?.string() ?? identity["alias"]?.string(), seen.insert(id).inserted else { return }
            let q = try quota.fields(["remainingFraction", "resetTime"])
            let fraction = q["remainingFraction"]?.number().flatMap { (0...1).contains($0) ? $0 : nil }
            let name = f["label"]?.string(limit: 128) ?? id
            let family = (id + " " + name).lowercased()
            guard family.contains("gemini") || family.contains("claude") || family.contains("gpt") else { return }
            let window = QuotaWindow(id: "model/" + id, usedPercent: fraction.map { (1 - $0) * 100 }, durationMinutes: nil,
                resetsAt: date(q["resetTime"]?.string()) ?? q["resetTime"]?.number().map { Date(timeIntervalSince1970: $0) })
            buckets.append(QuotaBucket(id: "model/" + id, name: name, plan: nil, windows: [window], credits: nil))
        }
        guard !buckets.isEmpty else { throw Failure.invalidResponse }
        return QuotaSnapshot(buckets: buckets, capturedAt: now, accountScope: nil, resetCredits: nil)
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let seconds = Double(text), seconds.isFinite { return Date(timeIntervalSince1970: seconds) }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }
}

/// Adapter 僅產生共用生命週期事件；斷線不產生完成通知。
public struct AntigravityActivityState: Sendable {
    private var sessions: [String: SessionActivity] = [:]
    private var baselined: Set<String> = []
    private var seenRequests: Set<String> = []
    private var pending: [String: PendingAttentionRequest] = [:]
    public init() {}
    public var activities: [SessionActivity] { sessions.values.sorted { $0.id < $1.id } }
    public var requests: [PendingAttentionRequest] { Array(pending.values) }
    public mutating func consume(_ observation: AntigravityAdapter.Observation, sourceID: String) {
        let o = observation, key = AgentProvider.antigravity.activityID(sessionID: o.sessionID, sourceHostID: sourceID)
        var value = sessions[key] ?? SessionActivity(id: key, project: "Antigravity", sourceHost: sourceID == "agy" ? "agy CLI" : "Antigravity IDE", sourceHostID: sourceID,
            phaseAwareRate: true, provider: .antigravity, sessionID: o.sessionID)
        let first = baselined.insert(key).inserted
        let at = max(o.observedAt, value.lastObserved ?? .distantPast)
        func event(_ method: String, _ fields: [String: Any] = [:]) -> [String: Any] {
            ["method": method, "threadId": o.sessionID, "turnId": o.turnID, "at": at.timeIntervalSince1970].merging(fields) { _, new in new }
        }
        if value.turnID != o.turnID || value.phase == .unknown {
            value.applyRuntime(event("turn/attached", ["startedAt": (o.startedAt ?? at).timeIntervalSince1970]))
        }
        var metadata: [String: Any] = [:]
        if let title = o.title { metadata["name"] = title }
        if let model = o.model { metadata["model"] = model }
        value.applyRuntime(event("metadata", metadata))
        pending[key] = nil
        switch o.phase {
        case .running:
            value.applyRuntime(event("thread/status/changed", ["status": "active"]))
            value.applyRuntime(event("item/started", ["itemId": "current", "itemType": o.stage == .tool ? "commandExecution" : o.stage == .responding ? "agentMessage" : "reasoning", "hasText": false]))
        case .waitingForInput:
            value.applyRuntime(event("thread/status/changed", ["status": "active", "flags": [o.approval ? "waitingOnApproval" : "waitingOnUserInput"]]))
            let requestID = key + ":" + o.attentionID
            let seen = !seenRequests.insert(requestID).inserted
            pending[key] = PendingAttentionRequest(id: requestID, threadID: o.sessionID, sourceHostID: sourceID,
                sourceName: sourceID == "agy" ? "agy CLI" : "Antigravity IDE", kind: o.approval ? .approval : .input,
                detectedAt: at, provider: .antigravity, suppressesNotice: first || seen)
        case .completed, .interrupted:
            value.applyRuntime(event("turn/completed", ["status": o.failed ? "failed" : o.phase == .completed ? "completed" : "interrupted"]))
        case .unknown: value.markSourceUnavailable()
        }
        if first { value.suppressHistoricalCompletionNotifications() }
        sessions[key] = value
        if sessions.count > 128, let oldest = sessions.min(by: { ($0.value.lastObserved ?? .distantPast) < ($1.value.lastObserved ?? .distantPast) })?.key {
            sessions[oldest] = nil; pending[oldest] = nil; baselined.remove(oldest)
            seenRequests = seenRequests.filter { !$0.hasPrefix(oldest + ":") }
        }
    }
    public mutating func unavailable(sourceID: String, keeping sessionIDs: Set<String> = []) {
        for key in sessions.keys where sessions[key]?.sourceHostID == sourceID && !sessionIDs.contains(sessions[key]?.threadID ?? "") {
            if [.running, .waitingForInput].contains(sessions[key]!.phase) { sessions[key]?.markSourceUnavailable() }
            pending[key] = nil
        }
    }
}
