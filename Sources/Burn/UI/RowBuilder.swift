import Foundation

enum ViewFilter: String, CaseIterable, Identifiable {
    case apps = "Apps & Services"
    case windowed = "Windowed Apps"
    case idle = "Hidden or Windowless Apps"
    case mine = "My Processes"
    case system = "System Processes"
    case all = "All Processes"

    var id: String { rawValue }

    /// Flat filters list processes one by one, like Activity Monitor's own views.
    var isFlat: Bool { self == .mine || self == .all }
}

struct RowComparator: SortComparator, Hashable {
    /// nil sorts by name.
    var metric: Metric?
    var order: SortOrder = .reverse

    func compare(_ a: Row, _ b: Row) -> ComparisonResult {
        let result: ComparisonResult
        if let metric, metric.isText {
            result = (a.text[metric] ?? "").localizedStandardCompare(b.text[metric] ?? "")
        } else if let metric {
            let x = a.value(metric) ?? -.infinity
            let y = b.value(metric) ?? -.infinity
            result = x == y ? a.name.localizedStandardCompare(b.name) : (x < y ? .orderedAscending : .orderedDescending)
        } else {
            result = a.name.localizedStandardCompare(b.name)
        }
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

enum RowBuilder {
    static let systemSectionID = "section.system"

    static func rows(snapshot: Snapshot, filter: ViewFilter, search: String,
                     extras: RowExtras, sort: [RowComparator]) -> [Row] {
        let now = snapshot.date
        let query = search.trimmingCharacters(in: .whitespaces)
        var rows: [Row]

        switch filter {
        case .apps:
            let visible = snapshot.groups.filter { matches($0, query) }
            rows = visible.filter { $0.kind != .system }.map { groupRow($0, extras: extras, now: now) }
            let system = visible.filter { $0.kind == .system }
            if !system.isEmpty { rows.append(sectionRow(system, extras: extras, now: now)) }
        case .windowed:
            rows = snapshot.groups
                .filter { $0.windows > 0 && matches($0, query) }
                .map { groupRow($0, extras: extras, now: now) }
        case .idle:
            rows = snapshot.groups
                .filter { $0.kind == .app && ($0.isHidden || $0.windows == 0) && matches($0, query) }
                .map { groupRow($0, extras: extras, now: now) }
        case .system:
            rows = snapshot.groups
                .filter { $0.kind == .system && matches($0, query) }
                .map { groupRow($0, extras: extras, now: now) }
        case .mine, .all:
            rows = snapshot.groups.flatMap { group in
                group.processes
                    .filter { filter == .all || $0.isOwn }
                    .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                        || group.name.localizedCaseInsensitiveContains(query) || String($0.pid) == query }
                    .map { processRow($0, group: group, extras: extras, now: now) }
            }
        }
        return sorted(rows, by: sort)
    }

    static func sorted(_ rows: [Row], by sort: [RowComparator]) -> [Row] {
        guard let comparator = sort.first else { return rows }
        return rows
            .sorted { comparator.compare($0, $1) == .orderedAscending }
            .map { row in
                var row = row
                if let children = row.children { row.children = sorted(children, by: sort) }
                return row
            }
    }

    private static func matches(_ group: AppGroup, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if group.name.localizedCaseInsensitiveContains(query) { return true }
        if group.bundleID?.localizedCaseInsensitiveContains(query) == true { return true }
        return group.processes.contains { $0.name.localizedCaseInsensitiveContains(query) || String($0.pid) == query }
    }

    // MARK: Groups

    static func groupRow(_ group: AppGroup, extras: RowExtras, now: Date) -> Row {
        var row = Row(id: "g\(group.id)", level: .group, name: group.name, group: group)
        row.values = [
            .cpu: group.cpuPercent, .cpuTime: group.cpuSeconds,
            .idleWakeups: group.idleWakeups, .gpu: group.gpuPercent, .gpuTime: group.gpuSeconds,
            .memory: Double(group.memory), .realMemory: Double(group.realMemory),
            .energy: group.energyImpact, .watts: group.watts,
            .diskRead: group.diskReadRate, .diskWrite: group.diskWriteRate,
            .diskReadTotal: Double(group.diskReadTotal), .diskWriteTotal: Double(group.diskWriteTotal),
            .processes: Double(group.processes.count), .pid: Double(group.leaderPID)
        ]
        // Thread counts of other users' processes can't be read; leave the cell empty rather than 0.
        if group.isOwn { row.values[.threads] = Double(group.threads) }
        if let growth = extras.memoryGrowthPerHour[group.historyKey] { row.values[.memoryTrend] = growth }
        if let average = extras.energyAverage[group.historyKey] { row.values[.energyAverage] = average }
        if let battery = extras.batteryToday[group.historyKey] { row.values[.batteryToday] = battery }
        if let lastActive = group.lastActive, group.kind == .app {
            row.values[.lastUsed] = group.isActive ? 0 : now.timeIntervalSince(lastActive)
        }
        if group.memoryIsEstimate { row.estimated.insert(.memory) }

        row.text[.user] = group.processes.first(where: { $0.pid == group.leaderPID })?.user ?? ""
        row.text[.kind] = group.kind.label
        row.text[.preventingSleep] = group.sleepAssertions.isEmpty ? "" : "Yes"
        row.badge = extras.badges[group.id] ?? defaultBadge(group, now: now)
        row.text[.status] = row.badge?.text ?? ""

        if group.processes.count > 1 {
            row.children = processChildren(group, extras: extras, now: now)
        } else {
            row.detail = group.processes.first.map { $0.name == group.name ? nil : $0.name } ?? nil
        }
        // A system service's name rarely says what it does; say it beside the name.
        if group.kind == .system, let info = ServiceKnowledge.info(for: leaderExecutable(group)) {
            row.detail = info.title
        }
        return row
    }

    private static func sectionRow(_ groups: [AppGroup], extras: RowExtras, now: Date) -> Row {
        var row = Row(id: systemSectionID, level: .section, name: "macOS & System Services")
        row.children = groups.map { groupRow($0, extras: extras, now: now) }
        row.detail = "\(groups.count) services"
        row.values = sum(row.children ?? [], [.cpu, .cpuTime, .threads, .idleWakeups, .gpu, .gpuTime, .memory, .realMemory,
                                             .energy, .watts, .diskRead, .diskWrite, .diskReadTotal, .diskWriteTotal, .processes])
        if groups.contains(where: \.memoryIsEstimate) { row.estimated.insert(.memory) }
        row.text[.kind] = GroupKind.system.label
        row.text[.user] = "root"
        return row
    }

    static func leaderExecutable(_ group: AppGroup) -> String {
        group.processes.first { $0.pid == group.leaderPID }?.name ?? group.name
    }

    private static func defaultBadge(_ group: AppGroup, now: Date) -> Badge? {
        guard group.kind == .app else { return nil }
        if group.isActive { return Badge(text: "Active", tone: .neutral) }
        if group.isHidden {
            if let since = group.hiddenSince {
                return Badge(text: "Hidden \(Format.duration(now.timeIntervalSince(since)))", tone: .neutral)
            }
            return Badge(text: "Hidden", tone: .neutral)
        }
        if group.windows == 0 { return Badge(text: "No windows", tone: .neutral) }
        return nil
    }

    // MARK: Processes

    /// Groups a coalition's processes by executable, so fourteen renderers read as
    /// one "Renderer ×14" row that expands, instead of fourteen near-identical lines.
    private static func processChildren(_ group: AppGroup, extras: RowExtras, now: Date) -> [Row] {
        let buckets = Dictionary(grouping: group.processes, by: \.name)
        return buckets.map { name, processes -> Row in
            if processes.count == 1 {
                return processRow(processes[0], group: group, extras: extras, now: now, nameInGroup: true)
            }
            var bucket = Row(id: "b\(group.id).\(name)", level: .bucket,
                             name: "\(helperLabel(name, app: group.name)) ×\(processes.count)", group: group)
            bucket.children = processes.map { processRow($0, group: group, extras: extras, now: now, nameInGroup: true) }
            bucket.values = sum(bucket.children ?? [], [.cpu, .cpuTime, .threads, .idleWakeups, .memory, .realMemory,
                                                        .energy, .watts, .diskRead, .diskWrite, .diskReadTotal, .diskWriteTotal])
            bucket.values[.processes] = Double(processes.count)
            if processes.contains(where: \.memoryIsEstimate) { bucket.estimated.insert(.memory) }
            bucket.detail = name
            bucket.text[.user] = processes[0].user
            return bucket
        }
    }

    static func processRow(_ process: ProcessStat, group: AppGroup, extras: RowExtras, now: Date,
                           nameInGroup: Bool = false) -> Row {
        let name = nameInGroup ? helperLabel(process.name, app: group.name) : process.name
        var row = Row(id: "p\(process.pid).\(process.identity.key.startMicros)", level: .process, name: name,
                      group: group, process: process)
        row.detail = nameInGroup ? (name == process.name ? nil : process.name) : group.name
        func set(_ metric: Metric, _ value: Double?) { if let value { row.values[metric] = value } }
        set(.cpu, process.cpuPercent)
        set(.cpuTime, process.cpuSeconds)
        set(.threads, process.threads.map(Double.init))
        set(.idleWakeups, process.idleWakeups)
        set(.memory, process.memory.map(Double.init))
        set(.realMemory, process.realMemory.map(Double.init))
        set(.energy, process.energyImpact)
        set(.watts, process.watts)
        set(.diskRead, process.diskReadRate)
        set(.diskWrite, process.diskWriteRate)
        set(.diskReadTotal, process.diskReadTotal.map(Double.init))
        set(.diskWriteTotal, process.diskWriteTotal.map(Double.init))
        row.values[.pid] = Double(process.pid)
        if process.memoryIsEstimate { row.estimated.insert(.memory) }
        row.text[.user] = process.user
        row.text[.kind] = group.kind.label
        row.text[.preventingSleep] = process.sleepAssertions.isEmpty ? "" : "Yes"
        return row
    }

    /// "Google Chrome Helper (Renderer)" in Google Chrome → "Renderer";
    /// "com.apple.WebKit.WebContent" → "Web Content".
    static func helperLabel(_ executable: String, app: String) -> String {
        let webKit = ["com.apple.WebKit.WebContent": "Web Content", "com.apple.WebKit.Networking": "Networking",
                      "com.apple.WebKit.GPU": "GPU", "com.apple.WebKit.Model": "Model"]
        if let label = webKit[executable] { return label }
        if let open = executable.lastIndex(of: "("), executable.hasSuffix(")"), executable.contains("Helper") {
            return String(executable[executable.index(after: open)..<executable.index(before: executable.endIndex)])
        }
        if executable.hasSuffix(" Helper") { return "Helper" }
        return executable
    }

    private static func sum(_ rows: [Row], _ metrics: [Metric]) -> [Metric: Double] {
        var totals: [Metric: Double] = [:]
        for metric in metrics {
            let values = rows.compactMap { $0.value(metric) }
            if !values.isEmpty { totals[metric] = values.reduce(0, +) }
        }
        return totals
    }
}
