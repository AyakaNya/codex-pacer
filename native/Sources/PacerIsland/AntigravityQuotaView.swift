import SwiftUI
import PacerCore

/// 每個 bucket 各畫一列，避免把不同模型或週期的額度混成同一個百分比。
struct AntigravityQuotaView: View {
    @ObservedObject var model: IslandModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(AgentProvider.antigravity.displayName).fontWeight(.semibold)
                if model.isDemo { Text(L10n.text("demo.label")).foregroundStyle(.secondary) }
            }
            if let snapshot = model.antigravityQuota {
                ForEach(snapshot.buckets) { bucket in
                    ForEach(bucket.windows) { window in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(bucket.name ?? bucket.id).lineLimit(2)
                                Spacer(minLength: 8)
                                Text(window.remainingPercent.map { String(format: "%.0f%%", $0) } ?? L10n.text("activity.unknown"))
                                    .monospacedDigit()
                            }
                            if let percent = window.remainingPercent {
                                ProgressView(value: percent, total: 100).tint(AgentProvider.antigravity.tint)
                            }
                            HStack {
                                Text(window.label)
                                Spacer()
                                if let reset = window.resetsAt {
                                    Text(L10n.text("antigravity.reset") + " " + reset.formatted(date: .abbreviated, time: .shortened))
                                }
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(L10n.text("antigravity.remaining") + " · " + QuotaDashboardPresentation.freshness(snapshot: snapshot, window: nil,
                    failed: model.antigravityQuotaUnavailable, refreshing: model.antigravityRefreshing, now: model.now))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text(L10n.text(model.antigravityRefreshing ? "quota.reading" : "antigravity.unavailable"))
                    .foregroundStyle(.secondary)
            }
        }.font(.system(size: 12)).padding(.horizontal, IslandMetrics.rowInset).padding(.vertical, 6)
    }
}
