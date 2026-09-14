import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var monitor: Monitor
    @EnvironmentObject private var engine: InsightEngine
    @EnvironmentObject private var preferences: Preferences
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let system = monitor.snapshot.system
        let symbol = engine.insights.runaways.isEmpty && system.pressure != .critical ? "flame" : "exclamationmark.triangle.fill"
        Group {
            switch preferences.menuBarLabel {
            case .power:
                Label(system.systemWatts.map { String(format: "%.1f W", $0) } ?? "—", systemImage: symbol)
            case .cpu:
                Label(String(format: "%.0f%%", 100 - system.cpuIdle), systemImage: symbol)
            case .memory:
                Label(system.pressure.label, systemImage: system.pressure == .normal ? symbol : "memorychip")
            case .iconOnly:
                Image(systemName: symbol)
            }
        }
        .labelStyle(.titleAndIcon)
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}

enum PopoverMetric: String, CaseIterable, Identifiable {
    case memory = "Memory", cpu = "CPU", power = "Power"

    var id: String { rawValue }
}

struct MenuBarView: View {
    @EnvironmentObject private var monitor: Monitor
    @EnvironmentObject private var engine: InsightEngine
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var metric: PopoverMetric = .memory
    @State private var unchecked: Set<String> = []

    var body: some View {
        let insights = engine.insights
        let system = monitor.snapshot.system
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(insights.pressure.headline).font(.headline)
                Spacer()
                if system.swapUsed >= 1_000_000_000 {
                    Text("\(Format.bytes(system.swapUsed)) swap")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(system.pressure.color)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(system.pressure.color.opacity(0.15)))
                }
            }

            HStack(spacing: 8) {
                Tile(label: "CPU", value: Format.percent(100 - system.cpuIdle, digits: 0))
                Tile(label: "Power", value: Format.watts(system.systemWatts))
                Tile(label: "Battery", value: batteryText(system.battery))
            }

            ForEach(insights.runaways) { runaway in
                PopoverAppRow(group: runaway.group, detail: "Stuck at \(Format.percent(runaway.cpu, digits: 0)) CPU", tone: .critical) {
                    Button("Force Quit…") { AppActions.forceQuit(runaway.group) }.controlSize(.small)
                }
            }
            ForEach(insights.hiddenBusy.prefix(2)) { finding in
                PopoverAppRow(group: finding.group, detail: "Busy while hidden · \(Format.percent(finding.averageCPU)) CPU", tone: .warning) {
                    Button("Quit") { AppActions.quit(finding.group) }.controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("TOP APPS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $metric) {
                        ForEach(PopoverMetric.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                    .controlSize(.small)
                }
                let top = topApps()
                let peak = top.map { value($0) }.max() ?? 1
                ForEach(top) { group in
                    HStack(spacing: 8) {
                        Image(nsImage: IconCache.icon(for: group)).resizable().frame(width: 18, height: 18)
                        Text(group.name).lineLimit(1)
                        Spacer(minLength: 8)
                        ProgressBar(fraction: value(group) / max(peak, 0.0001)).frame(width: 70, height: 4)
                        Text(formatted(group)).monospacedDigit().frame(width: 62, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }

            if !insights.suggestions.isEmpty {
                let selected = insights.suggestions.filter { !unchecked.contains($0.id) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("SUGGESTED TO CLOSE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("frees ≈ \(Format.bytes(selected.reduce(0) { $0 + $1.group.memory }))")
                            .font(.caption.weight(.semibold)).foregroundStyle(.green)
                    }
                    ForEach(insights.suggestions.prefix(5)) { suggestion in
                        Toggle(isOn: Binding(
                            get: { !unchecked.contains(suggestion.id) },
                            set: { on in if on { unchecked.remove(suggestion.id) } else { unchecked.insert(suggestion.id) } }
                        )) {
                            HStack(spacing: 8) {
                                Image(nsImage: IconCache.icon(for: suggestion.group)).resizable().frame(width: 22, height: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.group.name).font(.callout.weight(.medium))
                                    Text(suggestion.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    Button {
                        AppActions.quitAll(selected.map(\.group))
                    } label: {
                        Text(selected.count == 1 ? "Quit 1 App" : "Quit \(selected.count) Apps").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
                }
            }

            Divider()
            HStack {
                Button("Open Burn") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Settings…") {
                    openSettings()
                    NSApp.activate()
                }
                Button("Quit Burn") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { monitor.setVisible(true) }
        .onDisappear { monitor.setVisible(false) }
    }

    private func topApps() -> [AppGroup] {
        monitor.snapshot.groups
            .filter { $0.kind != .system }
            .sorted { value($0) > value($1) }
            .prefix(6)
            .map { $0 }
    }

    private func value(_ group: AppGroup) -> Double {
        switch metric {
        case .memory: Double(group.memory)
        case .cpu: group.cpuPercent
        case .power: group.watts
        }
    }

    private func formatted(_ group: AppGroup) -> String {
        switch metric {
        case .memory: Format.bytes(group.memory)
        case .cpu: Format.percent(group.cpuPercent)
        case .power: Format.watts(group.watts)
        }
    }

    private func batteryText(_ battery: BatteryState?) -> String {
        guard let battery else { return "—" }
        if battery.onExternalPower { return "\(battery.percent)% ⚡︎" }
        if let minutes = battery.minutesRemaining { return Format.duration(Double(minutes) * 60) }
        return "\(battery.percent)%"
    }
}

private struct Tile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

private struct PopoverAppRow<Trailing: View>: View {
    let group: AppGroup
    let detail: String
    let tone: Tone
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: IconCache.icon(for: group)).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(tone.color)
            }
            Spacer()
            trailing()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(tone.color.opacity(0.1)))
    }
}
