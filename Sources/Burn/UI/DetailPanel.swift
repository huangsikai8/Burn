import Charts
import SwiftUI

enum ChartMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU", memory = "Memory", energy = "Energy", watts = "Power"

    var id: String { rawValue }

    func value(_ point: HistoryPoint) -> Double {
        switch self {
        case .cpu: point.cpu
        case .memory: point.memory / 1_073_741_824
        case .energy: point.energy
        case .watts: point.watts
        }
    }

    var unit: String {
        switch self {
        case .cpu: "% CPU"
        case .memory: "GB"
        case .energy: "Energy Impact"
        case .watts: "W"
        }
    }

    var color: Color {
        switch self {
        case .cpu: .blue
        case .memory: .purple
        case .energy: .orange
        case .watts: .red
        }
    }
}

struct DetailPanel: View {
    let group: AppGroup
    let process: ProcessStat?
    let close: () -> Void
    let selectProcess: (ProcessStat) -> Void
    let selectGroup: (AppGroup) -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var monitor: Monitor
    @EnvironmentObject private var engine: InsightEngine
    @EnvironmentObject private var preferences: Preferences
    @State private var range: HistoryRange = .hour
    @State private var metric: ChartMetric = .cpu
    @State private var stored: [HistoryPoint] = []
    @State private var openFiles: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Button { close() } label: {
                    Label("Insights", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)

                header
                flags
                if group.kind == .system {
                    Card(title: "What this is") {
                        ServiceExplanation(finding: engine.serviceFinding(for: group), compact: false, select: selectGroup)
                    }
                }
                if let process { processCard(process) }
                statsCard
                historyCard
                processesCard
            }
            .padding(12)
        }
        .task(id: "\(group.historyKey)|\(range.rawValue)") {
            guard range != .hour else { return }
            model.history.series(key: group.historyKey, range: range) { stored = $0 }
        }
        .sheet(item: Binding(get: { openFiles.map { OpenFilesText(text: $0) } }, set: { openFiles = $0?.text })) { item in
            ScrollView([.vertical, .horizontal]) {
                Text(item.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding()
            }
            .frame(minWidth: 700, minHeight: 500)
        }
    }

    // MARK: Sections

    private var header: some View {
        Card(title: group.name) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: IconCache.icon(for: group)).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text([group.kind.label, group.bundleID].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(stateLine).font(.callout)
                    if let path = group.bundlePath {
                        Text(path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            HStack {
                Button("Quit") { AppActions.quit(group) }
                Button("Force Quit…") { AppActions.forceQuit(group) }
                Spacer()
                Menu {
                    if let path = group.bundlePath { Button("Reveal in Finder") { AppActions.reveal(path) } }
                    Button("Sample \(group.name)") { AppActions.sample(pid: group.leaderPID, name: group.name, isOwn: group.isOwn) }
                    Divider()
                    Button(preferences.isIgnored(group.historyKey) ? "Allow Suggestions and Alerts" : "Never Suggest or Alert") {
                        preferences.toggleIgnored(group.historyKey)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedWidth()
            }
        }
    }

    private var stateLine: String {
        var parts: [String] = []
        if group.isActive { parts.append("In use now") }
        else if group.isHidden { parts.append(group.hiddenSince.map { "Hidden \(Format.duration(Date().timeIntervalSince($0)))" } ?? "Hidden") }
        if group.kind == .app || group.kind == .menuBar {
            parts.append(group.windows == 1 ? "1 window" : "\(group.windows) windows")
        }
        if !group.isActive, let last = group.lastActive { parts.append("last used \(Format.ago(last))") }
        if let launch = group.launchDate { parts.append("running \(Format.duration(Date().timeIntervalSince(launch)))") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var flags: some View {
        let insights = engine.insights
        let lines: [(String, Tone)] = [
            insights.runaways.first { $0.group.id == group.id }.map { ("\($0.processName) has been stuck at \(Format.percent($0.cpu, digits: 0)) CPU for \(Format.duration($0.minutes * 60)).", Tone.critical) },
            insights.hiddenBusy.first { $0.group.id == group.id }.map { ("Using \(Format.percent($0.averageCPU)) CPU on average while \(group.isHidden ? "hidden" : "without windows").", Tone.warning) },
            insights.leaks.first { $0.key == group.historyKey }.map { ("Memory has grown \(Format.bytes($0.bytesPerHour)) an hour for \(Format.duration($0.hours * 3600)).", Tone.warning) },
            insights.suggestions.first { $0.group.id == group.id }.map { ("Suggested to close: \($0.summary).", Tone.info) },
            group.sleepAssertions.isEmpty ? nil : ("Preventing sleep: \(Set(group.sleepAssertions.map(\.name)).sorted().joined(separator: ", ")).", Tone.neutral)
        ].compactMap { $0 }
        if !lines.isEmpty {
            Card(title: "Why it stands out") {
                ForEach(lines, id: \.0) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(line.1.color).frame(width: 6, height: 6)
                        Text(line.0).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var statsCard: some View {
        let growth = engine.insights.extras.memoryGrowthPerHour[group.historyKey]
        return Card(title: "Now") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Stat(label: "CPU", value: Format.percent(group.cpuPercent))
                    Stat(label: "Memory", value: (group.memoryIsEstimate ? "~" : "") + Format.bytes(group.memory))
                    Stat(label: "Growth /h", value: growth.map { abs($0) < 1_048_576 ? "flat" : ($0 > 0 ? "+" : "−") + Format.bytes(abs($0)) } ?? "—")
                }
                GridRow {
                    Stat(label: "Energy Impact", value: Format.number(group.energyImpact))
                    Stat(label: "CPU Power", value: Format.watts(group.watts))
                    Stat(label: "GPU", value: Format.percent(group.gpuPercent))
                }
                GridRow {
                    Stat(label: "Idle Wakeups", value: "\(Int(group.idleWakeups))/s")
                    Stat(label: "Disk Read", value: Format.rate(group.diskReadRate))
                    Stat(label: "Disk Write", value: Format.rate(group.diskWriteRate))
                }
                GridRow {
                    Stat(label: "Processes", value: "\(group.processes.count)")
                    Stat(label: "Threads", value: group.isOwn ? "\(group.threads)" : "—")
                    Stat(label: "Ever started", value: "\(group.processesStarted)")
                }
                GridRow {
                    Stat(label: "CPU Time", value: Format.cpuTime(group.cpuSeconds))
                    Stat(label: "Total Written", value: Format.bytes(group.diskWriteTotal))
                    Stat(label: "Real Memory", value: Format.bytes(group.realMemory))
                }
            }
            if group.processesStarted > UInt64(group.processes.count) * 4 {
                Caption("Totals include \(group.processesStarted - UInt64(group.processes.count)) short-lived processes that have already exited — work Activity Monitor never shows.")
            }
        }
    }

    private var historyCard: some View {
        let points: [HistoryPoint] = range == .hour
            ? monitor.history(for: group.historyKey).map {
                HistoryPoint(date: $0.date, cpu: $0.cpu, memory: Double($0.memory), energy: $0.energy, watts: $0.watts)
            }
            : stored
        return Card(title: "History") {
            HStack {
                Picker("Metric", selection: $metric) {
                    ForEach(ChartMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedWidth()
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            if points.count < 2 {
                Caption(range == .hour ? "Collecting samples…" : "Not enough history yet. Burn records a point every minute while it runs.")
                    .frame(height: 140)
            } else {
                Chart(points) { point in
                    AreaMark(x: .value("Time", point.date), y: .value(metric.unit, metric.value(point)))
                        .foregroundStyle(metric.color.opacity(0.25))
                    LineMark(x: .value("Time", point.date), y: .value(metric.unit, metric.value(point)))
                        .foregroundStyle(metric.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                .chartYAxisLabel(metric.unit)
                .frame(height: 150)
            }
        }
    }

    private var processesCard: some View {
        let sorted = group.processes.sorted {
            switch metric {
            case .memory: ($0.memory ?? 0) > ($1.memory ?? 0)
            case .watts: ($0.watts ?? 0) > ($1.watts ?? 0)
            default: ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0)
            }
        }
        return Card(title: "Processes", trailing: "\(group.processes.count)") {
            ForEach(sorted.prefix(15)) { item in
                Button { selectProcess(item) } label: {
                    HStack {
                        Text(RowBuilder.helperLabel(item.name, app: group.name)).lineLimit(1)
                        Text("\(item.pid)").foregroundStyle(.tertiary)
                        Spacer()
                        Text(Format.percent(item.cpuPercent)).frame(width: 52, alignment: .trailing)
                        Text((item.memoryIsEstimate ? "~" : "") + Format.bytes(item.memory)).frame(width: 70, alignment: .trailing)
                    }
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(item.id == process?.id ? Color.accentColor : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if group.processes.count > 15 {
                Caption("\(group.processes.count - 15) more in the table.")
            }
        }
    }

    private func processCard(_ process: ProcessStat) -> some View {
        Card(title: process.name) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                field("PID", "\(process.pid)")
                field("Parent", "\(process.identity.ppid)")
                field("Responsible", process.identity.responsiblePID > 0 ? "\(process.identity.responsiblePID)" : "—")
                field("User", process.user)
                field("Started", process.identity.startDate.formatted(date: .abbreviated, time: .shortened))
                field("CPU", Format.percent(process.cpuPercent))
                field("CPU Time", Format.cpuTime(process.cpuSeconds))
                field("Memory", (process.memoryIsEstimate ? "~" : "") + Format.bytes(process.memory))
                field("Real Memory", Format.bytes(process.realMemory))
                field("Threads", process.threads.map(String.init) ?? "—")
                field("Energy Impact", Format.number(process.energyImpact))
                field("Disk Read / Written", "\(Format.bytes(process.diskReadTotal)) / \(Format.bytes(process.diskWriteTotal))")
                field("Path", process.identity.path.isEmpty ? "—" : process.identity.path)
            }
            if !process.isOwn {
                Caption("Owned by \(process.user). macOS only shares its CPU and energy through its group, and quitting it needs an administrator password.")
            }
            HStack {
                Button("Quit") { AppActions.quitProcess(process, in: group, force: false) }
                Button("Force Quit…") { AppActions.quitProcess(process, in: group, force: true) }
                Spacer()
                Button("Sample") { AppActions.sample(pid: process.pid, name: process.name, isOwn: process.isOwn) }
                Button("Open Files") { AppActions.openFiles(pid: process.pid) { openFiles = $0 } }
            }
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
        .font(.callout)
    }
}

private struct OpenFilesText: Identifiable {
    var id: Int { text.hashValue }
    let text: String
}
