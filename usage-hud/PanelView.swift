import SwiftUI
import ServiceManagement

struct PanelView: View {
    @ObservedObject var store: UsageStore
    var requestResize: () -> Void
    @State private var expanded: Set<String> = []

    /// 行間は Grid 全体で共通なので、セクションの見出し側に上余白を足して区切りを作る
    private let sectionGap: CGFloat = 8

    var body: some View {
        // ゲージ行を 1 つの Grid に集めて、ラベルと数値の列幅を実際の文言から揃える
        // (言語によって語長が変わるため、列幅は固定値で持たない)
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            header
            serviceSection(key: "claude", name: "Claude Code", usage: store.snapshot?.claude)
            serviceSection(key: "codex", name: "Codex", usage: store.snapshot?.codex)
            serviceSection(key: "copilot", name: "Copilot", usage: store.snapshot?.copilot)
            Divider()
                .padding(.top, sectionGap)
            systemSection
            footer
                .padding(.top, sectionGap)
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

    @ViewBuilder
    private func serviceSection(key: String, name: String, usage: ServiceUsage?) -> some View {
        SectionHeader(
            name: name,
            caption: usage?.detail,
            isExpanded: expanded.contains(key),
            hasDetails: !(usage?.details ?? []).isEmpty
        ) { toggle(key) }
            .padding(.top, sectionGap)
        if let usage {
            if let error = usage.error {
                // 前回値が残っている場合はエラーとゲージを併記する(値だけ消えると誤解を生む)
                Label(usage.gauges.isEmpty
                      ? error
                      : String(format: String(localized: "%@ — showing last value"), error),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(usage.gauges) { gauge in
                gaugeRow(
                    label: gauge.label,
                    fraction: gauge.usedPercent / 100,
                    trailing: String(format: String(localized: "%@ left"), percentText(gauge.remainingPercent)),
                    subtitle: gauge.resetsAt.map { "→ " + formatDetailDate($0) })
            }
            if expanded.contains(key), !usage.gauges.isEmpty, let details = usage.details {
                DetailList(items: details)
            }
        } else {
            Text("Loading…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var systemSection: some View {
        SectionHeader(
            name: String(localized: "System"),
            caption: nil,
            isExpanded: expanded.contains("system"),
            hasDetails: true
        ) { toggle("system") }
            .padding(.top, sectionGap)
        if let system = store.system {
            gaugeRow(
                label: "CPU",
                fraction: system.cpuPercent / 100,
                trailing: percentText(system.cpuPercent),
                subtitle: nil)
            gaugeRow(
                label: String(localized: "Memory"),
                fraction: Double(system.memUsedBytes) / Double(max(system.memTotalBytes, 1)),
                trailing: String(format: "%.1f / %.0f GB", system.memUsedGB, system.memTotalGB),
                subtitle: nil)
            if expanded.contains("system") {
                DetailList(items: memoryDetails(system))
            }
        }
    }

    // GridRow は Grid の直接の子である必要があるため、行はメソッドで組む(View に包まない)
    private func gaugeRow(
        label: String, fraction: Double, trailing: String, subtitle: String?
    ) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
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
            .gridColumnAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func memoryDetails(_ system: SystemSample) -> [DetailItem] {
        func gb(_ bytes: UInt64?) -> String {
            String(format: "%.1f GB", Double(bytes ?? 0) / 1_073_741_824)
        }
        return [
            DetailItem(label: String(localized: "Active"), value: gb(system.memActiveBytes)),
            DetailItem(label: String(localized: "Wired"), value: gb(system.memWiredBytes)),
            DetailItem(label: String(localized: "Compressed"), value: gb(system.memCompressedBytes)),
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
            .accessibilityLabel("Refresh now")
            Menu {
                LaunchAtLoginToggle()
                LanguagePicker()
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: DesignTokens.minHitTarget, height: DesignTokens.minHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Settings")
        }
    }

    private var footer: some View {
        HStack {
            if let fetched = store.snapshot?.fetchedAt {
                Text("Updated \(fetched.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
            Text("⌃⌥U to toggle")
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
                .accessibilityValue(isExpanded ? "Details shown" : "Details hidden")
                .accessibilityHint("Toggle details")
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

private struct LanguagePicker: View {
    @State private var selection = LanguageSetting.current

    var body: some View {
        Picker("Language", selection: $selection) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.label).tag(language)
            }
        }
        .onChange(of: selection) { _, language in
            LanguageSetting.apply(language)
        }
    }
}

private struct LaunchAtLoginToggle: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at login", isOn: Binding(
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
