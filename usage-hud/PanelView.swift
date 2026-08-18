import SwiftUI
import ServiceManagement

struct PanelView: View {
    @ObservedObject var store: UsageStore
    var requestResize: () -> Void
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            serviceSection(key: "claude", name: "Claude Code", usage: store.snapshot?.claude)
            serviceSection(key: "codex", name: "Codex", usage: store.snapshot?.codex)
            serviceSection(key: "copilot", name: "Copilot", usage: store.snapshot?.copilot)
            Divider()
            systemSection
            footer
        }
        .padding(16)
        .frame(width: DesignTokens.panelWidth)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.panelCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.panelCornerRadius)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    private func toggle(_ key: String) {
        if expanded.contains(key) {
            expanded.remove(key)
        } else {
            expanded.insert(key)
        }
        DispatchQueue.main.async { requestResize() }
    }

    private func serviceSection(key: String, name: String, usage: ServiceUsage?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(
                name: name,
                caption: usage?.detail,
                isExpanded: expanded.contains(key),
                hasDetails: !(usage?.details ?? []).isEmpty
            ) { toggle(key) }
            if let usage {
                if let error = usage.error {
                    // 前回値が残っている場合はエラーとゲージを併記する(値だけ消えると誤解を生む)
                    Label(usage.gauges.isEmpty ? error : "\(error) — 前回値を表示中",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(usage.gauges) { gauge in
                    GaugeRow(
                        label: gauge.label,
                        fraction: gauge.usedPercent / 100,
                        trailing: String(format: "残り %.0f%%", gauge.remainingPercent),
                        subtitle: gauge.resetsAt.map { "→ " + formatDetailDate($0) })
                }
                if expanded.contains(key), !usage.gauges.isEmpty, let details = usage.details {
                    DetailList(items: details)
                }
            } else {
                Text("取得中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(
                name: "システム",
                caption: nil,
                isExpanded: expanded.contains("system"),
                hasDetails: true
            ) { toggle("system") }
            if let system = store.system {
                GaugeRow(
                    label: "CPU",
                    fraction: system.cpuPercent / 100,
                    trailing: String(format: "%.0f%%", system.cpuPercent),
                    subtitle: nil)
                GaugeRow(
                    label: "メモリ",
                    fraction: Double(system.memUsedBytes) / Double(max(system.memTotalBytes, 1)),
                    trailing: String(format: "%.1f / %.0f GB", system.memUsedGB, system.memTotalGB),
                    subtitle: nil)
                if expanded.contains("system") {
                    DetailList(items: memoryDetails(system))
                }
            }
        }
    }

    private func memoryDetails(_ system: SystemSample) -> [DetailItem] {
        func gb(_ bytes: UInt64?) -> String {
            String(format: "%.1f GB", Double(bytes ?? 0) / 1_073_741_824)
        }
        return [
            DetailItem(label: "アクティブ", value: gb(system.memActiveBytes)),
            DetailItem(label: "確保済み (wired)", value: gb(system.memWiredBytes)),
            DetailItem(label: "圧縮", value: gb(system.memCompressedBytes)),
        ]
    }

    private var header: some View {
        HStack {
            Text("Usage HUD")
                .font(.headline)
            Spacer()
            Button {
                store.refresh(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .opacity(store.isRefreshing ? 0.3 : 1)
                    .frame(width: DesignTokens.minHitTarget, height: DesignTokens.minHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .accessibilityLabel("今すぐ更新")
            Menu {
                LaunchAtLoginToggle()
                Divider()
                Button("終了") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: DesignTokens.minHitTarget, height: DesignTokens.minHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("設定")
        }
    }

    private var footer: some View {
        HStack {
            if let fetched = store.snapshot?.fetchedAt {
                Text("更新 \(fetched.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
            Text("⌃⌥U で開閉")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct SectionHeader: View {
    let name: String
    let caption: String?
    let isExpanded: Bool
    let hasDetails: Bool
    let onToggle: () -> Void

    var body: some View {
        if hasDetails {
            Button(action: onToggle) { labelRow }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityValue(isExpanded ? "詳細を表示中" : "詳細は非表示")
                .accessibilityHint("詳細の表示を切り替え")
        } else {
            labelRow
        }
    }

    private var labelRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name)
                .font(.subheadline.weight(.semibold))
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if hasDetails {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(isExpanded ? .degrees(90) : .zero)
            }
            Spacer()
        }
        .frame(minHeight: DesignTokens.minHitTarget)
        .contentShape(Rectangle())
    }
}

private struct DetailList: View {
    let items: [DetailItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items) { item in
                HStack {
                    Text(item.label)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(item.value)
                        .monospacedDigit()
                }
                .font(.caption2)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.leading, 8)
        .padding(.vertical, 2)
    }
}

private struct GaugeRow: View {
    let label: String
    let fraction: Double
    let trailing: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            UsageBar(fraction: fraction)
            VStack(alignment: .trailing, spacing: 0) {
                Text(trailing)
                    .font(.caption.monospacedDigit())
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 84, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LaunchAtLoginToggle: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("ログイン時に起動", isOn: Binding(
            get: { isEnabled },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    isEnabled = newValue
                } catch {
                    isEnabled = SMAppService.mainApp.status == .enabled
                }
            }))
    }
}
