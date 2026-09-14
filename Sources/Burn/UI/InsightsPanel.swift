import SwiftUI

struct InsightsPanel: View {
    @EnvironmentObject private var engine: InsightEngine
    @EnvironmentObject private var monitor: Monitor
    let select: (AppGroup) -> Void

    var body: some View {
        let insights = engine.insights
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PressureCard(summary: insights.pressure, system: monitor.snapshot.system)

                if !insights.runaways.isEmpty {
                    Card(title: "Stuck at full CPU", tone: .critical) {
                        ForEach(insights.runaways) { finding in
                            AppLine(group: finding.group,
                                    subtitle: "\(finding.processName) · \(Format.percent(finding.cpu, digits: 0)) for \(Format.duration(finding.minutes * 60))",
                                    tone: .critical, select: select) {
                                Button("Force Quit…") { AppActions.forceQuit(finding.group) }
                            }
                        }
                    }
                }

                if !insights.systemBusy.isEmpty {
                    let total = insights.systemBusy.reduce(0) { $0 + $1.cpu }
                    Card(title: "Why macOS is busy", tone: .info, trailing: "\(Format.percent(total, digits: 0)) CPU") {
                        ForEach(insights.systemBusy) { finding in
                            ServiceExplanation(finding: finding, compact: true, select: select)
                            if finding.id != insights.systemBusy.last?.id { Divider() }
                        }
                    }
                }

                if !insights.suggestions.isEmpty {
                    Card(title: "Suggested to close", trailing: "frees ≈ \(Format.bytes(insights.suggestedBytes))", trailingTone: .good) {
                        ForEach(insights.suggestions) { suggestion in
                            AppLine(group: suggestion.group, subtitle: suggestion.summary, select: select) {
                                Button("Quit") { AppActions.quit(suggestion.group) }
                            }
                        }
                        if insights.suggestions.count > 1 {
                            Button {
                                AppActions.quitAll(insights.suggestions.map(\.group))
                            } label: {
                                Text("Quit All \(insights.suggestions.count)").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .help("Each app quits normally and asks about unsaved documents")
                        }
                    }
                }

                if !insights.hiddenBusy.isEmpty {
                    Card(title: "Busy while out of sight", tone: .warning) {
                        ForEach(insights.hiddenBusy) { finding in
                            AppLine(group: finding.group, subtitle: hiddenBusyText(finding), tone: .warning, select: select) {
                                Button("Quit") { AppActions.quit(finding.group) }
                            }
                        }
                    }
                }

                if !insights.leaks.isEmpty {
                    Card(title: "Memory keeps growing", tone: .warning) {
                        ForEach(insights.leaks) { leak in
                            if let group = leak.group {
                                AppLine(group: group,
                                        subtitle: "+\(Format.bytes(leak.bytesPerHour)) an hour for \(Format.duration(leak.hours * 3600)), now \(Format.bytes(leak.toBytes))",
                                        tone: .warning, select: select) {
                                    Button("Quit") { AppActions.quit(group) }
                                }
                            }
                        }
                        Caption("Steady growth with no drop-offs usually means a leak. Reopening the app gets the memory back.")
                    }
                }

                if !insights.batteryToday.isEmpty {
                    BatteryCard(shares: insights.batteryToday, groups: monitor.snapshot.groups, select: select)
                }

                if !insights.sleepBlockers.isEmpty {
                    Card(title: "Keeping the Mac awake") {
                        ForEach(insights.sleepBlockers) { blocker in
                            AppLine(group: blocker.group, subtitle: blocker.reasons.joined(separator: ", "), select: select) {
                                EmptyView()
                            }
                        }
                    }
                }

                if !insights.changes.isEmpty {
                    Card(title: "What changed recently") {
                        ForEach(insights.changes) { change in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(change.tone.color).frame(width: 6, height: 6)
                                Text(change.text).font(.callout)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { if let group = change.group { select(group) } }
                        }
                    }
                }

                if insights.pressure.level == .normal, insights.runaways.isEmpty, insights.suggestions.isEmpty,
                   insights.hiddenBusy.isEmpty, insights.leaks.isEmpty {
                    Card(title: "Nothing needs attention") {
                        Caption("No idle apps worth closing, nothing stuck and nothing busy in the background. Burn keeps watching from the menu bar.")
                    }
                }
            }
            .padding(12)
        }
    }

    private func hiddenBusyText(_ finding: HiddenBusyFinding) -> String {
        var parts = [finding.group.isHidden ? "Hidden" : "No windows"]
        parts.append("\(Format.percent(finding.averageCPU, digits: 1)) CPU")
        if finding.averageWakeups >= 50 { parts.append("\(Int(finding.averageWakeups)) wakeups/s") }
        if finding.averageWatts >= 0.05 { parts.append(Format.watts(finding.averageWatts)) }
        return parts.joined(separator: " · ") + " over \(Format.duration(finding.minutes * 60))"
    }
}

struct PressureCard: View {
    let summary: PressureSummary
    let system: SystemStats

    var body: some View {
        Card(title: summary.headline, tone: summary.tone) {
            VStack(alignment: .leading, spacing: 8) {
                ProgressBar(fraction: system.pressurePercent / 100, tint: system.pressure.color)
                    .frame(height: 6)
                HStack(spacing: 12) {
                    Stat(label: "Used", value: Format.bytes(system.usedMemory))
                    Stat(label: "Swap", value: Format.bytes(system.swapUsed))
                    Stat(label: "Compressed", value: Format.bytes(system.compressedMemory))
                }
                if !summary.body.isEmpty {
                    Text(summary.body)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct BatteryCard: View {
    let shares: [BatteryShare]
    let groups: [AppGroup]
    let select: (AppGroup) -> Void

    var body: some View {
        let total = shares.reduce(0) { $0 + $1.percent }
        let peak = shares.map(\.percent).max() ?? 1
        Card(title: "Battery used today", trailing: "≈ \(Format.percent(total, digits: 0)) total") {
            ForEach(shares.prefix(7)) { share in
                HStack(spacing: 8) {
                    if let group = groups.first(where: { $0.historyKey == share.key }) {
                        Image(nsImage: IconCache.icon(for: group)).resizable().frame(width: 16, height: 16)
                    } else {
                        Image(systemName: share.key == BatteryShare.otherKey ? "display" : "app.dashed")
                            .frame(width: 16, height: 16).foregroundStyle(.secondary)
                    }
                    Text(share.name).font(.callout).lineLimit(1)
                    Spacer(minLength: 8)
                    ProgressBar(fraction: share.percent / peak, tint: .orange).frame(width: 60, height: 4)
                    Text(share.percent < 0.1 ? "<0.1%" : Format.percent(share.percent))
                        .font(.callout.monospacedDigit()).frame(width: 48, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if let group = groups.first(where: { $0.historyKey == share.key }) { select(group) }
                }
            }
            Caption("Estimated from each app’s CPU energy while on battery. Screen, radios and GPU work are counted under “other”.")
        }
    }
}

/// What a system service is, the measured conditions behind its load, the apps
/// that look responsible, and what to do. Compact in the sidebar, full in details.
struct ServiceExplanation: View {
    let finding: ServiceFinding
    let compact: Bool
    let select: (AppGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if compact {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(finding.executable).font(.callout.weight(.semibold)).lineLimit(1)
                    if let title = finding.info?.title {
                        Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(Format.percent(finding.cpu, digits: 0)).font(.callout.weight(.medium).monospacedDigit())
                }
                .contentShape(Rectangle())
                .onTapGesture { select(finding.group) }
            }

            if let info = finding.info {
                if !compact {
                    Text(info.what).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Heading("Why it gets busy")
                }
                Text(info.whyBusy)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(compact ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No description is available for this service.").font(.callout)
                let leader = finding.group.processes.first { $0.pid == finding.group.leaderPID } ?? finding.group.processes.first
                let path = leader?.identity.path ?? ""
                if !path.isEmpty {
                    Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(finding.evidence, id: \.self) { line in
                Bullet(text: line, color: .orange, font: compact ? .caption : .callout)
            }

            if !finding.contributors.isEmpty {
                Heading("Likely causes")
                ForEach(finding.contributors) { contributor in
                    HStack(spacing: 8) {
                        Image(nsImage: IconCache.icon(for: contributor.group)).resizable().frame(width: 18, height: 18)
                        Text(contributor.group.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text(contributor.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { select(contributor.group) }
                }
            }

            if let reduce = finding.info?.reduce, !reduce.isEmpty {
                Heading("How to reduce it")
                ForEach(reduce.prefix(compact ? 2 : reduce.count), id: \.self) { tip in
                    Bullet(text: tip, color: .secondary, font: compact ? .caption : .callout)
                }
            }
        }
    }
}

private struct Heading: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
    }
}

private struct Bullet: View {
    let text: String
    let color: Color
    let font: Font

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(font).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Building blocks

enum CardTone {
    case good
}

struct Card<Content: View>: View {
    let title: String
    var tone: Tone = .neutral
    var trailing: String?
    var trailingTone: CardTone?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if tone != .neutral {
                    Circle().fill(tone.color).frame(width: 8, height: 8)
                }
                Text(title).font(.headline)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(trailingTone == .good ? Color.green : Color.secondary)
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}

struct AppLine<Trailing: View>: View {
    let group: AppGroup
    let subtitle: String
    var tone: Tone = .neutral
    let select: (AppGroup) -> Void
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(for: group))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            trailing()
        }
        .contentShape(Rectangle())
        .onTapGesture { select(group) }
    }
}

struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium).monospacedDigit())
        }
    }
}

struct Caption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
