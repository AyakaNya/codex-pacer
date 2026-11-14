import Darwin
import Foundation
import PacerCore
import Security

public enum AntigravityApplicationResolver {
    public static func find() -> URL? {
        let catalog = MacApplicationCatalog(), home = FileManager.default.homeDirectoryForCurrentUser
        return catalog.locations(for: .antigravity, userHome: home).first { catalog.isApplication($0, provider: .antigravity) }
    }
}

/// 只讀取同一使用者已啟動的 Language Server；不啟動 agy，也不接觸登入資料。
public enum MacAntigravityDiscovery {
    public struct Endpoint: Sendable {
        public let pid: pid_t
        public let sourceID: String
        public let port: Int
        public let csrfToken: String
        public let startedAt: Date
    }
    public static func discover() -> [Endpoint] {
        var result: [Endpoint] = []
        for pid in CodexRolloutOwners.userProcesses().prefix(2048) {
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executable = String(cString: path), lower = executable.lowercased()
            let name = URL(fileURLWithPath: executable).lastPathComponent
            let cli = name == "agy" || name == "antigravity_cli" || name == "antigravity-cli"
            let server = (name.hasPrefix("language_server") || name == "language-server") && lower.contains("antigravity")
            guard cli || server, let start = ProcessOwnership.processStartDate(pid) else { continue }
            let token = csrfToken(pid: pid, cli: cli)
            for port in listeningPorts(pid).sorted().prefix(4) {
                result.append(Endpoint(pid: pid, sourceID: cli ? "agy" : "antigravity-ide", port: port, csrfToken: token, startedAt: start))
            }
            if result.count >= 12 { break }
        }
        return result
    }
    /// 僅取 RPC 的 CSRF 握手值；不讀取環境變數、Keychain 或 OAuth token。
    private static func csrfToken(pid: pid_t, cli: Bool) -> String {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 256 * 1024 else { return "" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard bytes.withUnsafeMutableBytes({ sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }) == 0 else { return "" }
        let count = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard (1...256).contains(count), let end = bytes[4..<size].firstIndex(of: 0) else { return "" }
        var cursor = end + 1
        while cursor < size && bytes[cursor] == 0 { cursor += 1 }
        var wantsValue = false
        for index in 0..<count {
            guard cursor < size, let end = bytes[cursor..<size].firstIndex(of: 0) else { return "" }
            defer { cursor = end + 1 }
            if wantsValue {
                guard end - cursor <= 256, let token = String(bytes: bytes[cursor..<end], encoding: .utf8), !token.hasPrefix("-") else { return "" }
                return token
            }
            // CLI 的第一個參數以外可能是 Prompt；不解碼其他 CLI 參數。
            if cli && index > 1 { break }
            guard end - cursor <= 512, let arg = String(bytes: bytes[cursor..<end], encoding: .utf8) else { continue }
            if arg == "--csrf_token" || arg == "-csrf_token" { wantsValue = true }
            if arg.hasPrefix("--csrf_token=") { return String(arg.dropFirst(13)) }
        }
        return ""
    }
    private static func listeningPorts(_ pid: pid_t) -> Set<Int> {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0, size <= 4096 * MemoryLayout<proc_fdinfo>.stride else { return [] }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 8)
        let read = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard read > 0 else { return [] }
        var ports: Set<Int> = []
        for fd in descriptors.prefix(Int(read) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let expected = Int32(MemoryLayout<socket_fdinfo>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, expected) == expected,
                  info.psi.soi_kind == SOCKINFO_TCP, info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports
    }
}

private final class AntigravityLocalTrust: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.host == "127.0.0.1",
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

public actor MacAntigravityReader {
    public struct Reading: Sendable {
        public let activities: [SessionActivity]
        public let requests: [PendingAttentionRequest]
        public let quota: QuotaSnapshot?
        public let connected: Bool
        public let quotaAvailable: Bool
    }
    private enum Method: String { case summaries = "GetAllCascadeTrajectories", trajectory = "GetCascadeTrajectory", quota = "RetrieveUserQuotaSummary", status = "GetUserStatus" }
    private var state = AntigravityActivityState()
    private var quota: QuotaSnapshot?
    private var lastQuota = Date.distantPast
    private var offset = 0
    private var servers: Set<String> = []
    private var quotaAvailable = false
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 2; config.timeoutIntervalForResource = 5
        session = URLSession(configuration: config, delegate: AntigravityLocalTrust(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func read(forceQuota: Bool = false, now: Date = Date()) async -> Reading {
        let endpoints = await Task.detached(priority: .utility) { MacAntigravityDiscovery.discover() }.value
        if Task.isCancelled { return currentReading(connected: false) }
        let identities = Set(endpoints.map { "\($0.pid):\($0.startedAt.timeIntervalSince1970)" })
        if identities != servers { quota = nil; lastQuota = .distantPast; servers = identities; quotaAvailable = false }
        var connectedSources: Set<String> = [], quotaRead: QuotaSnapshot?
        var confirmedBySource: [String: Set<String>] = [:], readProcesses: Set<pid_t> = []
        let wantsQuota = forceQuota || now.timeIntervalSince(lastQuota) >= 60
        for endpoint in endpoints.sorted(by: { $0.sourceID == "agy" && $1.sourceID != "agy" }) where !readProcesses.contains(endpoint.pid) {
            guard !Task.isCancelled else { break }
            // 先測 HTTP；各版本同時提供 HTTP 與本機自簽 HTTPS。
            for scheme in ["http", "https"] {
                if Task.isCancelled { break }
                guard ProcessOwnership.processStartDate(endpoint.pid) == endpoint.startedAt else { continue }
                do {
                    let summaries = try AntigravityAdapter.summaries(await call(.summaries, endpoint: endpoint, scheme: scheme))
                    connectedSources.insert(endpoint.sourceID)
                    readProcesses.insert(endpoint.pid)
                    let running = summaries.filter(\.running), idle = summaries.filter { !$0.running }
                    let rotated = idle.isEmpty ? [] : Array(idle.dropFirst(offset % idle.count)) + Array(idle.prefix(offset % idle.count))
                    var confirmed: Set<String> = []
                    for summary in Array((running + rotated).prefix(16)) {
                        try Task.checkCancellation()
                        do {
                            let bytes = try await call(.trajectory, endpoint: endpoint, scheme: scheme, sessionID: summary.id)
                            let observation = try AntigravityAdapter.trajectory(bytes, sessionID: summary.id, title: summary.title, running: summary.running ? true : summary.idle ? false : nil, now: now)
                            state.consume(observation, sourceID: endpoint.sourceID); confirmed.insert(summary.id)
                        } catch { continue }
                    }
                    // 未讀取成功的執行中會話會在本輪結束時標成 Unknown。
                    confirmedBySource[endpoint.sourceID, default: []].formUnion(confirmed)
                    if wantsQuota {
                        if let bytes = try? await call(.quota, endpoint: endpoint, scheme: scheme),
                           let snapshot = try? AntigravityAdapter.quota(bytes, now: now) {
                            if quotaRead == nil || quotaRead?.buckets.first?.id.hasPrefix("model/") == true { quotaRead = snapshot }
                        } else if quotaRead == nil, let bytes = try? await call(.status, endpoint: endpoint, scheme: scheme),
                                  let snapshot = try? AntigravityAdapter.legacyQuota(bytes, now: now) { quotaRead = snapshot }
                    }
                    break
                } catch { continue }
            }
        }
        if Task.isCancelled { return currentReading(connected: false) }
        offset = (offset + 16) % 2048
        for source in ["agy", "antigravity-ide"] { state.unavailable(sourceID: source, keeping: confirmedBySource[source] ?? []) }
        if wantsQuota { lastQuota = now; quotaAvailable = quotaRead != nil }
        if let quotaRead { quota = quotaRead }
        return currentReading(connected: !connectedSources.isEmpty)
    }
    private func currentReading(connected: Bool) -> Reading {
        Reading(activities: state.activities, requests: state.requests, quota: quota, connected: connected, quotaAvailable: quotaAvailable)
    }
    private func call(_ method: Method, endpoint: MacAntigravityDiscovery.Endpoint, scheme: String, sessionID: String? = nil) async throws -> Data {
        guard ProcessOwnership.processStartDate(endpoint.pid) == endpoint.startedAt else { throw AntigravityAdapter.Failure.invalidResponse }
        let url = URL(string: "\(scheme)://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/\(method.rawValue)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if !endpoint.csrfToken.isEmpty { request.setValue(endpoint.csrfToken, forHTTPHeaderField: "x-codeium-csrf-token") }
        request.httpBody = try JSONSerialization.data(withJSONObject: sessionID.map { ["cascadeId": $0] } ?? [:])
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AntigravityAdapter.Failure.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            if data.count >= 16 * 1024 * 1024 { throw AntigravityAdapter.Failure.invalidResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
}
