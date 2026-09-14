import AppKit

struct CloseSuggestion: Identifiable {
    var id: String { group.historyKey }
    let group: AppGroup
    let score: Double
    /// "Hidden 3 h · 1.4 GB · 0.4 W"
    let summary: String
}

struct HiddenBusyFinding: Identifiable {
    var id: String { group.historyKey }
    let group: AppGroup
    let averageCPU: Double
    let averageWakeups: Double
    let averageWatts: Double
    let minutes: Double
}

struct RunawayFinding: Identifiable {
    var id: String { "\(group.historyKey).\(processName)" }
    let group: AppGroup
    let processName: String
    let pid: pid_t?
    let cpu: Double
    let minutes: Double
}

struct LeakFinding: Identifiable {
    var id: String { key }
    let key: String
    let name: String
    let bytesPerHour: Double
    let hours: Double
    let fromBytes: Double
    let toBytes: Double
    var group: AppGroup?
}

struct SleepBlocker: Identifiable {
    var id: String { group.historyKey }
    let group: AppGroup
    let reasons: [String]
}

struct ChangeFinding: Identifiable {
    let id: String
    let text: String
    let tone: Tone
    var group: AppGroup?
}

struct Contributor: Identifiable {
    var id: UInt64 { group.id }
    let group: AppGroup
    let detail: String
}

/// A system service using notable CPU, with what it is and what's measurably behind it.
struct ServiceFinding: Identifiable {
    var id: UInt64 { group.id }
    let group: AppGroup
    let executable: String
    let info: ServiceInfo?
    /// Average over the last minute.
    let cpu: Double
    /// Measured conditions that explain the load: heat, swapping, disk activity.
    let evidence: [String]
    /// Apps whose measured activity matches what this service does for them.
    let contributors: [Contributor]
}

struct PressureSummary {
    var level: PressureLevel = .normal
    var tone: Tone = .neutral
    var headline = "Collecting data…"
    var body = ""
    var consumers: [AppGroup] = []
}

struct Insights {
    var pressure = PressureSummary()
    var suggestions: [CloseSuggestion] = []
    var hiddenBusy: [HiddenBusyFinding] = []
    var runaways: [RunawayFinding] = []
    var leaks: [LeakFinding] = []
    var sleepBlockers: [SleepBlocker] = []
    var changes: [ChangeFinding] = []
    var systemBusy: [ServiceFinding] = []
    var batteryToday: [BatteryShare] = []
    var extras = RowExtras()

    var suggestedBytes: UInt64 { suggestions.reduce(0) { $0 + $1.group.memory } }
    var alertCount: Int { runaways.count + hiddenBusy.count + leaks.count }
}

/// Turns snapshots and history into the recommendations shown in the sidebar,
/// the menu bar and notifications. Every rule reports and explains; none act.
@MainActor
final class InsightEngine: ObservableObject {
    @Published private(set) var insights = Insights()

    private let monitor: Monitor
    private let preferences: Preferences
    private let history: HistoryStore
    private var leakFindings: [LeakFinding] = []
    private var batteryShares: [BatteryShare] = []
    private var lastSlowRefresh = Date.distantPast

    /// Apps never worth suggesting: quitting them is either impossible or pointless.
    private static let neverSuggest: Set<String> = [
        "com.apple.finder", "com.sikaihuang.Burn", "com.apple.ActivityMonitor", "com.apple.dock"
    ]

    init(monitor: Monitor, preferences: Preferences, history: HistoryStore) {
        self.monitor = monitor
        self.preferences = preferences
        self.history = history
        monitor.subscribe { [weak self] snapshot in self?.evaluate(snapshot) }
    }

    func refreshSoon() {
        lastSlowRefresh = .distantPast
        evaluate(monitor.snapshot)
    }

    private func evaluate(_ snapshot: Snapshot) {
        let now = snapshot.date
        var result = Insights()
        result.suggestions = closeSuggestions(snapshot, now: now)
        result.hiddenBusy = hiddenBusy(snapshot, now: now)
        result.runaways = runaways(snapshot, now: now)
        result.sleepBlockers = sleepBlockers(snapshot)
        result.changes = changes(snapshot, now: now)
        result.systemBusy = systemBusy(snapshot, now: now)
        result.pressure = pressure(snapshot, suggestions: result.suggestions)

        let byKey = Dictionary(snapshot.groups.map { ($0.historyKey, $0) }, uniquingKeysWith: { a, b in a.memory >= b.memory ? a : b })
        result.leaks = leakFindings.compactMap { finding in
            guard let group = byKey[finding.key] else { return nil }
            var live = finding
            live.group = group
            return live
        }
        result.batteryToday = batteryShares
        result.extras = extras(snapshot, result, now: now)
        insights = result

        if now.timeIntervalSince(lastSlowRefresh) > 300 {
            lastSlowRefresh = now
            refreshFromHistory()
        }
    }

    // MARK: Close suggestions

    private func closeSuggestions(_ snapshot: Snapshot, now: Date) -> [CloseSuggestion] {
        let idleThreshold = preferences.idleHours * 3600
        let minimumBytes = preferences.suggestMinimumMB * 1_048_576
        var suggestions: [CloseSuggestion] = []

        for group in snapshot.groups where group.kind == .app && group.isOwn && !group.isActive {
            if let id = group.bundleID, Self.neverSuggest.contains(id) { continue }
            if preferences.isIgnored(group.historyKey) { continue }
            // Something is actively using it: audio, a call, a download keeping the Mac awake.
            if !group.sleepAssertions.isEmpty { continue }
            if runsExternalWork(group) { continue }

            let points = monitor.history(for: group.historyKey)
            let recent = window(points, minutes: 10, now: now)
            let watts = average(recent, \.watts) ?? group.watts
            let cpu = average(recent, \.cpu) ?? group.cpuPercent
            let diskWrite = group.diskWriteRate
            if diskWrite > 2_000_000 { continue }

            let idle = idleDuration(group, snapshot: snapshot, now: now)
            let hiddenFor = group.hiddenSince.map { now.timeIntervalSince($0) }
            let windowless = group.windows == 0
            let longIdle = idle.seconds >= idleThreshold
            let longHidden = (hiddenFor ?? 0) >= idleThreshold
            let idleWindowless = windowless && idle.seconds >= min(1800, idleThreshold)
            guard longIdle || longHidden || idleWindowless else { continue }

            let heavy = Double(group.memory) >= minimumBytes || watts >= 0.3 || cpu >= 3
            guard heavy else { continue }

            let hours = max(idle.seconds, hiddenFor ?? 0) / 3600
            let gb = Double(group.memory) / 1_073_741_824
            let score = (gb + watts * 1.5 + cpu / 10) * log2(2 + hours)

            var parts: [String] = []
            if let hiddenFor, group.isHidden {
                parts.append("Hidden \(Format.duration(hiddenFor))")
            } else if windowless {
                parts.append("No windows")
            }
            if !group.isHidden || hiddenFor == nil {
                parts.append((idle.exact ? "Unused " : "Unused ≥ ") + Format.duration(idle.seconds))
            }
            parts.append(Format.bytes(group.memory))
            if watts >= 0.1 { parts.append(Format.watts(watts)) }
            suggestions.append(CloseSuggestion(group: group, score: score, summary: parts.joined(separator: " · ")))
        }
        return Array(suggestions.sorted { $0.score > $1.score }.prefix(8))
    }

    /// How long since the app was frontmost. When it hasn't been frontmost since we
    /// started watching, the true figure is unknown and at least the watch time.
    private func idleDuration(_ group: AppGroup, snapshot: Snapshot, now: Date) -> (seconds: TimeInterval, exact: Bool) {
        if let last = group.lastActive { return (now.timeIntervalSince(last), true) }
        let floor = max(snapshot.trackingSince, group.launchDate ?? snapshot.trackingSince)
        return (now.timeIntervalSince(floor), group.launchDate.map { $0 > snapshot.trackingSince } ?? false)
    }

    /// A terminal running a build, an editor running a language server: the coalition
    /// holds busy executables from outside the app's bundle, so quitting would kill work.
    private func runsExternalWork(_ group: AppGroup) -> Bool {
        guard let bundle = group.bundlePath else { return false }
        return group.processes.contains { process in
            !process.identity.path.hasPrefix(bundle) && (process.cpuPercent ?? 0) > 1
        }
    }

    // MARK: Detectors

    private func hiddenBusy(_ snapshot: Snapshot, now: Date) -> [HiddenBusyFinding] {
        let minutes = preferences.hiddenBusyMinutes
        return snapshot.groups.compactMap { group in
            guard group.kind == .app, group.isHidden || group.windows == 0, !group.isActive else { return nil }
            guard !preferences.isIgnored(group.historyKey) else { return nil }
            let points = monitor.history(for: group.historyKey)
            guard covers(points, minutes: minutes, now: now) else { return nil }
            let recent = window(points, minutes: minutes, now: now)
            let cpu = average(recent, \.cpu) ?? 0
            let wakeups = average(recent, \.idleWakeups) ?? 0
            let watts = average(recent, \.watts) ?? 0
            guard cpu >= preferences.hiddenBusyCPU || wakeups >= 150 else { return nil }
            // Playing audio or holding a call is legitimate background work.
            guard group.sleepAssertions.isEmpty else { return nil }
            return HiddenBusyFinding(group: group, averageCPU: cpu, averageWakeups: wakeups, averageWatts: watts, minutes: minutes)
        }
        .sorted { $0.averageCPU > $1.averageCPU }
    }

    private func runaways(_ snapshot: Snapshot, now: Date) -> [RunawayFinding] {
        let minutes = preferences.runawayMinutes
        let threshold = preferences.runawayCPU
        return snapshot.groups.compactMap { group in
            guard !preferences.isIgnored(group.historyKey) else { return nil }
            let points = monitor.history(for: group.historyKey)
            guard covers(points, minutes: minutes, now: now) else { return nil }
            let recent = window(points, minutes: minutes, now: now)
            guard recent.count >= 3, recent.allSatisfy({ $0.hottestProcessCPU >= threshold }) else { return nil }
            // The same process must be the hot one throughout, or it's just a busy app.
            let keys = Set(recent.compactMap(\.hottestProcess))
            guard keys.count <= 1 else { return nil }
            let process = keys.first.flatMap { key in group.processes.first { $0.id == key } }
            let cpu = recent.map(\.hottestProcessCPU).reduce(0, +) / Double(recent.count)
            return RunawayFinding(group: group, processName: process?.name ?? group.name, pid: process?.pid ?? group.leaderPID,
                                  cpu: cpu, minutes: now.timeIntervalSince(recent.first?.date ?? now) / 60)
        }
        .sorted { $0.cpu > $1.cpu }
    }

    private func sleepBlockers(_ snapshot: Snapshot) -> [SleepBlocker] {
        snapshot.groups.compactMap { group in
            guard !group.sleepAssertions.isEmpty else { return nil }
            let reasons = Array(Set(group.sleepAssertions.map { Self.describe($0) })).sorted()
            return SleepBlocker(group: group, reasons: reasons)
        }
        .sorted { $0.group.name < $1.group.name }
    }

    private static func describe(_ assertion: SleepAssertion) -> String {
        let name = assertion.name.lowercased()
        if name.contains("audio") { return "Playing or recording audio" }
        if name.contains("video") || name.contains("playback") { return "Playing video" }
        if name.contains("download") { return "Downloading" }
        if assertion.type.contains("Display") { return "Keeping the display on" }
        return assertion.name.count > 60 ? String(assertion.name.prefix(57)) + "…" : assertion.name
    }

    // MARK: Busy system services

    /// System services averaging at least 8% of a core over the last minute.
    private func systemBusy(_ snapshot: Snapshot, now: Date) -> [ServiceFinding] {
        let busy: [(Double, AppGroup)] = snapshot.groups.filter { $0.kind == .system }.compactMap { group in
            let recent = window(monitor.history(for: group.historyKey), minutes: 1, now: now)
            let cpu = average(recent, \.cpu) ?? group.cpuPercent
            return cpu >= 8 ? (cpu, group) : nil
        }
        return busy.sorted { $0.0 > $1.0 }.prefix(4).map { serviceFinding(for: $0.1, snapshot: snapshot, cpu: $0.0) }
    }

    /// The explanation for any service, busy or not, for the detail panel.
    func serviceFinding(for group: AppGroup) -> ServiceFinding {
        if let existing = insights.systemBusy.first(where: { $0.group.id == group.id }) { return existing }
        return serviceFinding(for: group, snapshot: monitor.snapshot, cpu: group.cpuPercent)
    }

    private func serviceFinding(for group: AppGroup, snapshot: Snapshot, cpu: Double) -> ServiceFinding {
        let executable = RowBuilder.leaderExecutable(group)
        let info = ServiceKnowledge.info(for: executable)
        let apps = snapshot.groups.filter { $0.kind != .system }
        let s = snapshot.system
        var evidence: [String] = []
        var contributors: [Contributor] = []

        for hint in info?.hints ?? [] {
            switch hint {
            case .onScreenApps:
                let drawing = apps
                    .filter { $0.onscreenWindows > 0 && $0.cpuPercent + $0.gpuPercent >= 1 }
                    .sorted { $0.cpuPercent + 2 * $0.gpuPercent > $1.cpuPercent + 2 * $1.gpuPercent }
                for app in drawing.prefix(4) {
                    var detail = "\(app.onscreenWindows) window\(app.onscreenWindows == 1 ? "" : "s") on screen · \(Format.percent(app.cpuPercent)) CPU"
                    if app.gpuPercent >= 0.5 { detail += " · \(Format.percent(app.gpuPercent)) GPU" }
                    contributors.append(Contributor(group: app, detail: detail))
                }
                let windows = apps.reduce(0) { $0 + $1.onscreenWindows }
                if windows > 0 { evidence.append("\(windows) windows are on screen right now.") }
            case .audioApps:
                for app in apps where app.sleepAssertions.contains(where: { $0.name.lowercased().contains("audio") }) {
                    contributors.append(Contributor(group: app, detail: "Playing or recording audio"))
                }
            case .processSpawners:
                for app in snapshot.groups.filter({ $0.spawnsPerMinute >= 20 && $0.id != group.id })
                    .sorted(by: { $0.spawnsPerMinute > $1.spawnsPerMinute }).prefix(3) {
                    contributors.append(Contributor(group: app, detail: "Starting \(Int(app.spawnsPerMinute)) processes a minute"))
                }
            case .statsTools:
                let tools = ["com.apple.ActivityMonitor", "com.bjango.istatmenus", "eu.exelban.Stats"]
                for app in apps where tools.contains(app.bundleID ?? "") {
                    contributors.append(Contributor(group: app, detail: "Refreshes statistics for every process"))
                }
            case .memoryHogs:
                guard s.swapInsPerSecond + s.swapOutsPerSecond >= 50 || s.pressure != .normal else { continue }
                for app in apps.sorted(by: { $0.memory > $1.memory }).prefix(3) {
                    contributors.append(Contributor(group: app, detail: "Uses \(Format.bytes(app.memory))"))
                }
            case .diskWriters:
                for app in snapshot.groups.filter({ $0.diskWriteRate >= 1_000_000 && $0.id != group.id })
                    .sorted(by: { $0.diskWriteRate > $1.diskWriteRate }).prefix(3) {
                    contributors.append(Contributor(group: app, detail: "Writing \(Format.rate(app.diskWriteRate))"))
                }
            case .thermal:
                if s.thermal != .nominal {
                    evidence.append("The Mac’s thermal state is \(s.thermal.label.lowercased()), so macOS is spending CPU time to cool it.")
                } else {
                    evidence.append("The Mac isn’t running hot, so this isn’t heat management.")
                }
            case .swapActivity:
                let pages = s.swapInsPerSecond + s.swapOutsPerSecond
                if pages >= 50 {
                    evidence.append("Memory is moving to and from swap at \(Int(pages)) pages a second.")
                }
                if s.diskReadRate + s.diskWriteRate >= 20_000_000 {
                    evidence.append("The disk is busy: \(Format.rate(s.diskReadRate)) read and \(Format.rate(s.diskWriteRate)) written.")
                }
            }
        }

        var seen = Set<UInt64>()
        contributors = contributors.filter { seen.insert($0.group.id).inserted }
        return ServiceFinding(group: group, executable: executable, info: info, cpu: cpu,
                              evidence: evidence, contributors: Array(contributors.prefix(4)))
    }

    // MARK: What changed

    private func changes(_ snapshot: Snapshot, now: Date) -> [ChangeFinding] {
        var found: [(Double, ChangeFinding)] = []
        for group in snapshot.groups {
            let points = monitor.history(for: group.historyKey)
            guard let first = points.first else { continue }

            if now.timeIntervalSince(first.date) < 600, now.timeIntervalSince(monitor.trackingStart) > 900 {
                if group.memory > 700_000_000 || group.cpuPercent > 25 {
                    found.append((Double(group.memory) / 1e8 + group.cpuPercent, ChangeFinding(
                        id: "new.\(group.historyKey)",
                        text: "\(group.name) started \(Format.ago(group.launchDate, now: now)) and is using \(Format.bytes(group.memory))",
                        tone: .info, group: group)))
                }
                continue
            }

            let last2 = window(points, minutes: 2, now: now)
            let before = points.filter { $0.date < now.addingTimeInterval(-120) && $0.date >= now.addingTimeInterval(-720) }
            if let recentCPU = average(last2, \.cpu), let earlierCPU = average(before, \.cpu), before.count >= 3,
               recentCPU >= 25, recentCPU >= earlierCPU * 3 + 5 {
                found.append((recentCPU, ChangeFinding(
                    id: "cpu.\(group.historyKey)",
                    text: "\(group.name) jumped to \(Format.percent(recentCPU, digits: 0)) CPU (was \(Format.percent(earlierCPU, digits: 0)))",
                    tone: .warning, group: group)))
            }
            if let old = points.last(where: { $0.date <= now.addingTimeInterval(-600) }) {
                let growth = Double(group.memory) - Double(old.memory)
                if growth >= 1_000_000_000 {
                    found.append((growth / 1e8, ChangeFinding(
                        id: "mem.\(group.historyKey)",
                        text: "\(group.name) grew by \(Format.bytes(growth)) in \(Format.duration(now.timeIntervalSince(old.date)))",
                        tone: .warning, group: group)))
                }
            }
            if group.spawnsPerMinute >= 120 {
                found.append((group.spawnsPerMinute / 10, ChangeFinding(
                    id: "spawn.\(group.historyKey)",
                    text: "\(group.name) is starting \(Int(group.spawnsPerMinute)) processes a minute",
                    tone: .warning, group: group)))
            }
        }

        let system = monitor.systemHistory
        if let old = system.last(where: { $0.date <= now.addingTimeInterval(-600) }) {
            let growth = Double(snapshot.system.swapUsed) - Double(old.swapUsed)
            if growth >= 1_000_000_000 {
                found.append((growth / 1e8, ChangeFinding(
                    id: "swap", text: "Swap grew by \(Format.bytes(growth)) in the last \(Format.duration(now.timeIntervalSince(old.date)))",
                    tone: .warning)))
            }
        }
        return found.sorted { $0.0 > $1.0 }.prefix(8).map(\.1)
    }

    // MARK: Memory pressure

    private func pressure(_ snapshot: Snapshot, suggestions: [CloseSuggestion]) -> PressureSummary {
        let s = snapshot.system
        var summary = PressureSummary(level: s.pressure)
        let ram = Double(max(s.physicalMemory, 1))
        let swapHeavy = Double(s.swapUsed) > ram * 0.25

        switch s.pressure {
        case .critical:
            summary.tone = .critical
            summary.headline = "Memory is critically low"
        case .warning:
            summary.tone = .warning
            summary.headline = "Memory pressure is high"
        case .normal:
            summary.tone = swapHeavy ? .info : .neutral
            summary.headline = swapHeavy ? "Memory is coping, but swap is large" : "Memory is fine"
        }

        summary.consumers = snapshot.groups
            .filter { $0.kind != .system }
            .sorted { $0.memory > $1.memory }
            .prefix(3)
            .map { $0 }

        var sentences: [String] = []
        if s.swapUsed >= 1_000_000_000 {
            sentences.append("\(Format.bytes(s.swapUsed)) of memory has been moved onto the disk (swap), which is much slower than RAM.")
        }
        if Double(s.compressedMemory) > ram * 0.25 {
            sentences.append("Another \(Format.bytes(s.compressedMemory)) is compressed to fit in \(Format.bytes(s.physicalMemory)) of RAM.")
        }
        let named = summary.consumers.prefix(2).map { "\($0.name) (\(Format.bytes($0.memory)))" }
        if named.count == 2 {
            sentences.append("\(named[0]) and \(named[1]) use the most.")
        } else if let only = named.first {
            sentences.append("\(only) uses the most.")
        }
        if !suggestions.isEmpty {
            let bytes = suggestions.reduce(0) { $0 + $1.group.memory }
            let count = suggestions.count == 1 ? "the idle app" : "the \(suggestions.count) idle apps"
            sentences.append("Quitting \(count) below would free about \(Format.bytes(bytes)).")
        }
        if s.swapOutsPerSecond > 100 {
            sentences.append("Memory is being written to disk right now.")
        } else if swapHeavy && s.pressure == .normal {
            sentences.append("Swap shrinks gradually after apps quit, so it can lag behind.")
        }
        summary.body = sentences.joined(separator: " ")
        return summary
    }

    // MARK: Table extras

    private func extras(_ snapshot: Snapshot, _ result: Insights, now: Date) -> RowExtras {
        var extras = RowExtras()
        for group in snapshot.groups {
            let points = monitor.history(for: group.historyKey)
            if let slope = memorySlope(points, now: now) { extras.memoryGrowthPerHour[group.historyKey] = slope }
            if let energy = average(points, \.energy) { extras.energyAverage[group.historyKey] = energy }
        }
        for share in result.batteryToday { extras.batteryToday[share.key] = share.percent }

        for suggestion in result.suggestions {
            extras.badges[suggestion.group.id] = Badge(text: "Suggest quit", tone: .info)
        }
        for leak in result.leaks {
            if let group = leak.group {
                extras.badges[group.id] = Badge(text: "Growing +\(Format.bytes(leak.bytesPerHour))/h", tone: .warning)
            }
        }
        for finding in result.hiddenBusy {
            extras.badges[finding.group.id] = Badge(text: finding.group.isHidden ? "Hidden, busy" : "No windows, busy", tone: .warning)
        }
        for runaway in result.runaways {
            extras.badges[runaway.group.id] = Badge(text: "Runaway \(Format.percent(runaway.cpu, digits: 0))", tone: .critical)
        }
        return extras
    }

    // MARK: Slow refresh from the database

    private func refreshFromHistory() {
        let threshold = preferences.leakMBPerHour * 1_048_576
        history.findLeaks(minimumBytesPerHour: threshold) { [weak self] leaks in
            self?.leakFindings = leaks
        }
        history.batteryToday { [weak self] shares in
            self?.batteryShares = shares
        }
    }

    // MARK: Helpers

    private func window(_ points: [GroupPoint], minutes: Double, now: Date) -> [GroupPoint] {
        let cutoff = now.addingTimeInterval(-minutes * 60)
        return points.filter { $0.date >= cutoff }
    }

    /// History reaches back far enough to judge a window of this length.
    private func covers(_ points: [GroupPoint], minutes: Double, now: Date) -> Bool {
        guard let first = points.first else { return false }
        return now.timeIntervalSince(first.date) >= minutes * 60 * 0.9
    }

    /// Time-weighted, since samples arrive every 2 s or every 10 s depending on visibility.
    private func average(_ points: [GroupPoint], _ value: KeyPath<GroupPoint, Double>) -> Double? {
        guard points.count >= 2 else { return points.first?[keyPath: value] }
        var total = 0.0, weight = 0.0
        for (previous, point) in zip(points, points.dropFirst()) {
            let gap = min(15, point.date.timeIntervalSince(previous.date))
            total += point[keyPath: value] * gap
            weight += gap
        }
        return weight > 0 ? total / weight : nil
    }

    /// Least-squares memory growth in bytes per hour over the in-memory hour.
    private func memorySlope(_ points: [GroupPoint], now: Date) -> Double? {
        guard let first = points.first, now.timeIntervalSince(first.date) >= 900, points.count >= 10 else { return nil }
        let xs = points.map { $0.date.timeIntervalSince(first.date) / 3600 }
        let ys = points.map { Double($0.memory) }
        return LinearFit(xs: xs, ys: ys)?.slope
    }
}

struct LinearFit {
    let slope: Double
    let intercept: Double
    let r2: Double

    init?(xs: [Double], ys: [Double]) {
        let n = Double(xs.count)
        guard xs.count == ys.count, xs.count >= 3 else { return nil }
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in zip(xs, ys) {
            sxy += (x - mx) * (y - my)
            sxx += (x - mx) * (x - mx)
            syy += (y - my) * (y - my)
        }
        guard sxx > 0 else { return nil }
        slope = sxy / sxx
        intercept = my - slope * mx
        r2 = syy > 0 ? (sxy * sxy) / (sxx * syy) : 0
    }
}
