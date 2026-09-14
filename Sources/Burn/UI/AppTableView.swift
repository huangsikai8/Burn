import SwiftUI

struct RowActions {
    var quit: (Row) -> Void
    var forceQuit: (Row) -> Void
    var reveal: (Row) -> Void
    var inspect: (Row) -> Void
    var sample: (Row) -> Void
    var ignore: (Row) -> Void
}

struct AppTableView: View {
    let rows: [Row]
    let tab: ViewTab
    @Binding var selection: Row.ID?
    @Binding var sortOrder: [RowComparator]
    let actions: RowActions

    var body: some View {
        let peak = rows.compactMap { $0.value(tab.primary) }.max() ?? 0
        Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", sortUsing: RowComparator(metric: nil, order: .forward)) { row in
                NameCell(row: row)
            }
            .width(min: 200, ideal: 250)

            TableColumnForEach(tab.columns) { metric in
                TableColumn(metric.title, sortUsing: RowComparator(metric: metric)) { row in
                    MetricCell(row: row, metric: metric, peak: metric == tab.primary ? peak : nil)
                }
                // The primary column carries an inline bar, so it needs room for bar and figure.
                .width(min: metric == tab.primary ? 104 : metric.width.min,
                       ideal: metric == tab.primary ? 120 : metric.width.ideal)
                .alignment(metric.isText ? .leading : .trailing)
            }
        }
        .id(tab)
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if let row = find(ids.first) {
                Button("Show Details") { actions.inspect(row) }
                Divider()
                Button(row.level == .process ? "Quit Process" : "Quit") { actions.quit(row) }
                    .disabled(row.level == .section)
                Button(row.level == .process ? "Force Quit Process" : "Force Quit") { actions.forceQuit(row) }
                    .disabled(row.level == .section)
                Divider()
                Button("Sample Process") { actions.sample(row) }
                    .disabled(row.process == nil && row.group == nil)
                Button("Reveal in Finder") { actions.reveal(row) }
                    .disabled(row.group?.bundlePath == nil && row.process?.identity.path.isEmpty != false)
                Button("Don’t Suggest This App") { actions.ignore(row) }
                    .disabled(row.group?.kind != .app && row.group?.kind != .menuBar)
                Divider()
                Button("Copy Name") { copy(row.name) }
                if let pid = row.process?.pid ?? row.group?.leaderPID {
                    Button("Copy PID") { copy(String(pid)) }
                }
            }
        } primaryAction: { ids in
            if let row = find(ids.first) { actions.inspect(row) }
        }
    }

    private func find(_ id: Row.ID?, in list: [Row]? = nil) -> Row? {
        guard let id else { return nil }
        for row in list ?? rows {
            if row.id == id { return row }
            if let match = find(id, in: row.children ?? []) { return match }
        }
        return nil
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct NameCell: View {
    let row: Row

    var body: some View {
        HStack(spacing: 7) {
            icon
            Text(row.name)
                .fontWeight(row.level == .group || row.level == .section ? .medium : .regular)
                .foregroundStyle(row.level == .process || row.level == .bucket ? .secondary : .primary)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = row.detail {
                // The description gives way first; the name is what identifies the row.
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .help(row.process?.identity.path ?? row.group?.bundlePath ?? row.name)
    }

    @ViewBuilder private var icon: some View {
        switch row.level {
        case .group:
            if let group = row.group {
                Image(nsImage: IconCache.icon(for: group))
                    .resizable()
                    .frame(width: 18, height: 18)
            }
        case .section:
            Image(systemName: "applelogo")
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
        case .bucket:
            Image(systemName: "square.stack")
                .font(.caption)
                .frame(width: 14)
                .foregroundStyle(.tertiary)
        case .process:
            EmptyView()
        }
    }
}

struct MetricCell: View {
    let row: Row
    let metric: Metric
    /// Largest top-level value in the primary column, for the inline bar.
    let peak: Double?

    var body: some View {
        if metric == .status, let badge = row.badge {
            BadgeView(badge: badge)
        } else if let peak, peak > 0, let value = row.value(metric), row.level == .group || row.level == .section {
            HStack(spacing: 6) {
                ProgressBar(fraction: value / peak)
                    .frame(width: 28, height: 4)
                text
            }
        } else {
            text
        }
    }

    private var text: some View {
        Text(Self.format(row, metric))
            .monospacedDigit()
            .foregroundStyle(row.level == .process || row.level == .bucket ? .secondary : .primary)
            .fontWeight(peak != nil && row.level != .process ? .medium : .regular)
            .lineLimit(1)
    }

    static func format(_ row: Row, _ metric: Metric) -> String {
        if metric.isText { return row.text[metric] ?? "" }
        guard let value = row.value(metric) else { return "—" }
        let prefix = row.estimated.contains(metric) ? "~" : ""
        switch metric {
        case .cpu, .gpu, .energy, .energyAverage: return Format.number(value)
        case .cpuTime, .gpuTime: return Format.cpuTime(value)
        case .threads, .processes, .pid: return String(Int(value))
        case .idleWakeups: return Format.number(value, digits: 0)
        case .memory, .realMemory, .diskReadTotal, .diskWriteTotal: return prefix + Format.bytes(value)
        case .memoryTrend:
            guard abs(value) >= 1_048_576 else { return "—" }
            return (value > 0 ? "+" : "−") + Format.bytes(abs(value))
        case .watts: return Format.watts(value)
        case .batteryToday: return value < 0.05 ? "<0.1%" : Format.percent(value)
        case .diskRead, .diskWrite: return Format.rate(value)
        case .lastUsed: return value < 1 ? "Now" : Format.duration(value)
        default: return Format.number(value)
        }
    }
}

struct BadgeView: View {
    let badge: Badge

    var body: some View {
        Text(badge.text)
            .font(.caption.weight(badge.tone == .neutral ? .regular : .semibold))
            .foregroundStyle(badge.tone.color)
            .padding(.horizontal, badge.tone == .neutral ? 0 : 6)
            .padding(.vertical, 1)
            .background {
                if badge.tone != .neutral {
                    Capsule().fill(badge.tone.color.opacity(0.14))
                }
            }
            .lineLimit(1)
    }
}

struct ProgressBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: max(proxy.size.height, proxy.size.width * min(1, max(0, fraction))))
            }
        }
    }
}

extension Tone {
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}
