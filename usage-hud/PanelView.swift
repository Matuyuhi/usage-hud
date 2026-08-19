import SwiftUI
import ServiceManagement

struct PanelView: View {
    @ObservedObject var store: UsageStore
    var requestResize: () -> Void
    @State private var expanded: Set<String> = []

    /// 行間は Grid 全体で共通なので、セクションの見出し側に上余白を足して区切りを作る
    private let sectionGap: CGFloat = 8

    private var services: [DisplayItem] { DisplayItem.services.filter { store.isEnabled($0) } }
    private var systemMetrics: [DisplayItem] { DisplayItem.systemMetrics.filter { store.isEnabled($0) } }

    var body: some View {
        // ゲージ行を 1 つの Grid に集めて、ラベルと数値の列幅を実際の文言から揃える
        // (言語によって語長が変わるため、列幅は固定値で持たない)
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            header
            ForEach(services) { service in
                serviceSection(service)
            }
            if !systemMetrics.isEmpty {
                if !services.isEmpty {
                    Divider()
                        .padding(.top, sectionGap)
                }
                systemSection
            }
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
        resizeAfterLayout()
    }

    /// 行数が変わる操作の後に、パネルを実際の内容の高さへ合わせ直す
    private func resizeAfterLayout() {
        DispatchQueue.main.async { requestResize() }
    }

    private func serviceUsage(for service: DisplayItem) -> ServiceUsage? {
        switch service {
        case .claude: store.snapshot?.claude
        case .codex: store.snapshot?.codex
        case .copilot: store.snapshot?.copilot
        default: nil
        }
    }

    @ViewBuilder
    private func serviceSection(_ service: DisplayItem) -> some View {
        let usage = serviceUsage(for: service)
        SectionHeader(
            name: service.title,
            caption: usage?.detail,
            isExpanded: expanded.contains(service.rawValue),
            hasDetails: !(usage?.details ?? []).isEmpty
        ) { toggle(service.rawValue) }
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
            if expanded.contains(service.rawValue), !usage.gauges.isEmpty, let details = usage.details {
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
        let system = store.system
        let details = system.map { systemDetails($0) } ?? []
        SectionHeader(
            name: String(localized: "System"),
            caption: nil,
            isExpanded: expanded.contains("system"),
            hasDetails: !details.isEmpty
        ) { toggle("system") }
            .padding(.top, sectionGap)
        if let system {
            let rows = systemMetrics.compactMap { metricRow(for: $0, system: system) }
            ForEach(rows) { row in
                gaugeRow(
                    label: row.label,
                    fraction: row.fraction,
                    severity: row.severity,
                    trailing: row.trailing,
                    subtitle: row.subtitle)
            }
            // バッテリーを表示する設定でも、内蔵バッテリーの無い Mac では行が作れない
            if systemMetrics.contains(.battery), system.battery == nil {
                Text("No built-in battery")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if expanded.contains("system"), !details.isEmpty {
                DetailList(items: details)
            }
        }
    }

    /// システム指標 1 行分。バーを持たない指標(ネットワーク)は fraction を nil にする
    private struct MetricRow: Identifiable {
        var id: String { label }
        let label: String
        let fraction: Double?
        var severity: Double? = nil
        let trailing: String
        var subtitle: String? = nil
    }

    private func metricRow(for metric: DisplayItem, system: SystemSample) -> MetricRow? {
        switch metric {
        case .cpu:
            guard let cpu = system.cpuPercent else { return nil }
            return MetricRow(label: metric.title, fraction: cpu / 100, trailing: percentText(cpu))
        case .memory:
            guard let fraction = system.memFraction else { return nil }
            return MetricRow(
                label: metric.title,
                fraction: fraction,
                trailing: String(format: "%.1f / %.0f GB", system.memUsedGB, system.memTotalGB))
        case .battery:
            guard let battery = system.battery else { return nil }
            return MetricRow(
                label: metric.title,
                fraction: battery.fraction,
                // 残量は多いほど良いので、配色は「不足量」で判定する。給電中は警告色を出さない
                severity: battery.isPluggedIn ? 0 : 1 - battery.fraction,
                trailing: percentText(battery.percent),
                subtitle: batterySubtitle(battery))
        case .disk:
            guard let disk = system.disk else { return nil }
            return MetricRow(
                label: metric.title,
                fraction: disk.fraction,
                trailing: percentText(disk.fraction * 100),
                subtitle: String(format: String(localized: "%@ free"), byteText(disk.freeBytes)))
        case .network:
            guard let network = system.network else { return nil }
            return MetricRow(
                label: metric.title,
                fraction: nil,
                trailing: "↓ " + rateText(network.inBytesPerSecond),
                subtitle: "↑ " + rateText(network.outBytesPerSecond))
        default:
            return nil
        }
    }

    /// 給電中は稲妻を出す。残り時間は macOS が算出中の間は出さない
    private func batterySubtitle(_ battery: BatterySample) -> String? {
        if battery.isCharging {
            return battery.minutesToFull.map { "⚡ " + durationText($0) } ?? "⚡"
        }
        if battery.isPluggedIn { return "⚡" }
        return battery.minutesToEmpty.map { durationText($0) }
    }

    // GridRow は Grid の直接の子である必要があるため、行はメソッドで組む(View に包まない)
    private func gaugeRow(
        label: String, fraction: Double?, severity: Double? = nil, trailing: String, subtitle: String?
    ) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let fraction {
                UsageBar(fraction: fraction, severity: severity)
            } else {
                Color.clear.frame(height: DesignTokens.barHeight)
            }
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

    /// 展開時の内訳。表示している指標の分だけ組み立てる
    private func systemDetails(_ system: SystemSample) -> [DetailItem] {
        func gb(_ bytes: UInt64?) -> String {
            String(format: "%.1f GB", Double(bytes ?? 0) / 1_073_741_824)
        }
        var items: [DetailItem] = []
        if systemMetrics.contains(.memory), system.memUsedBytes != nil {
            items += [
                DetailItem(label: String(localized: "Active"), value: gb(system.memActiveBytes)),
                DetailItem(label: String(localized: "Wired"), value: gb(system.memWiredBytes)),
                DetailItem(label: String(localized: "Compressed"), value: gb(system.memCompressedBytes)),
            ]
        }
        if systemMetrics.contains(.battery), let battery = system.battery {
            let state = battery.isCharging
                ? String(localized: "Charging")
                : (battery.isPluggedIn ? String(localized: "Plugged in") : String(localized: "On battery"))
            items.append(DetailItem(label: String(localized: "Power source"), value: state))
            if let minutes = battery.minutesToFull {
                items.append(DetailItem(label: String(localized: "Time to full"), value: durationText(minutes)))
            } else if let minutes = battery.minutesToEmpty {
                items.append(DetailItem(label: String(localized: "Time remaining"), value: durationText(minutes)))
            }
            if let health = battery.health {
                items.append(DetailItem(label: String(localized: "Condition"), value: health))
            }
        }
        if systemMetrics.contains(.disk), let disk = system.disk {
            items.append(DetailItem(label: String(localized: "Disk free"), value: byteText(disk.freeBytes)))
            items.append(DetailItem(label: String(localized: "Disk capacity"), value: byteText(disk.totalBytes)))
        }
        if systemMetrics.contains(.network), let network = system.network {
            // 累計はインターフェースが上がってからの合計(通常は起動時から)
            items.append(DetailItem(label: String(localized: "Received"), value: byteText(network.totalInBytes)))
            items.append(DetailItem(label: String(localized: "Sent"), value: byteText(network.totalOutBytes)))
        }
        return items
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
                DisplayItemPicker(store: store, onChange: resizeAfterLayout)
                Divider()
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

/// 表示項目の選択。外した項目は取得もしなくなるので、使わないサービスを外せば負荷も減る
private struct DisplayItemPicker: View {
    @ObservedObject var store: UsageStore
    let onChange: () -> Void

    var body: some View {
        Menu("Display items") {
            ForEach(DisplayItem.services) { item in
                toggle(item)
            }
            Divider()
            ForEach(DisplayItem.systemMetrics) { item in
                toggle(item)
            }
        }
    }

    private func toggle(_ item: DisplayItem) -> some View {
        Toggle(item.title, isOn: Binding(
            get: { store.isEnabled(item) },
            set: { isOn in
                store.setEnabled(item, isOn)
                onChange()
            }))
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
