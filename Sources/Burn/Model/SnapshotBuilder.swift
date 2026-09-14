import AppKit
import Darwin

/// Turns raw counters into per-app groups with rates. Runs on the sampling queue.
///
/// Groups are resource coalitions. Group totals come from the coalition's own
/// counters rather than summing members, because those include helpers that
/// started and exited between samples — Chrome alone churns through tens of
/// thousands of them, which a process list never sees.
final class SnapshotBuilder {
    private let processSampler = ProcessSampler()
    private let systemSampler = SystemSampler()
    private let foreignMemory = ForeignProcessMemory()
    private let energy = EnergyModel.system
    private let ownUID = getuid()

    private var lastTime: UInt64 = 0
    private var lastSampleDate = Date.distantPast
    private var lastProcesses: [ProcessKey: ProcessCounters] = [:]
    private var lastCoalitions: [UInt64: CoalitionCounters] = [:]
    private var currentCoalitions: [UInt64: CoalitionCounters] = [:]
    private var userNames: [uid_t: String] = [:]
    private var bundleInfo: [String: (name: String?, id: String?)] = [:]

    func build(census: Census) -> Snapshot {
        let now = Clock.uptimeNs()
        let date = Date()
        let seconds = lastTime == 0 ? 0 : Double(now - lastTime) / 1e9
        let intervalNs = Double(now - lastTime)

        let raw = processSampler.sample()
        let system = systemSampler.sample()
        foreignMemory.refresh()
        let windows = WindowCensus.countsByPID()
        let assertions = PowerAssertions.current()

        currentCoalitions = raw.coalitions
        var membersByCoalition: [UInt64: [RawProcess]] = [:]
        for process in raw.processes {
            membersByCoalition[process.identity.resourceCoalition, default: []].append(process)
        }

        var groups: [AppGroup] = []
        groups.reserveCapacity(membersByCoalition.count)
        for (coalition, members) in membersByCoalition {
            let stats = members.map { processStat($0, seconds: seconds, intervalNs: intervalNs, assertions: assertions) }
            groups.append(makeGroup(coalition: coalition, members: members, stats: stats, census: census,
                                    windows: windows, seconds: seconds, intervalNs: intervalNs))
        }

        var nextProcesses: [ProcessKey: ProcessCounters] = [:]
        for process in raw.processes {
            if let counters = process.counters { nextProcesses[process.identity.key] = counters }
        }
        lastProcesses = nextProcesses
        lastCoalitions = raw.coalitions
        lastTime = now
        lastSampleDate = date

        return Snapshot(date: date, interval: seconds, groups: groups, system: system, trackingSince: census.trackingSince)
    }

    // MARK: Processes

    private func processStat(_ raw: RawProcess, seconds: Double, intervalNs: Double,
                             assertions: [pid_t: [SleepAssertion]]) -> ProcessStat {
        let identity = raw.identity
        var stat = ProcessStat(identity: identity, name: identity.executableName,
                               user: userName(identity.uid), isOwn: identity.uid == ownUID)
        stat.sleepAssertions = assertions[identity.pid] ?? []

        guard let counters = raw.counters else {
            if let memory = foreignMemory.memory(for: identity.pid) {
                stat.memory = memory.bytes
                stat.memoryIsEstimate = !memory.exact
            }
            stat.realMemory = foreignMemory.resident[identity.pid]
            return stat
        }

        stat.memory = counters.footprint
        stat.realMemory = counters.resident
        stat.threads = counters.threads
        stat.cpuSeconds = Double(counters.cpuNs) / 1e9
        stat.diskReadTotal = counters.diskRead
        stat.diskWriteTotal = counters.diskWrite

        guard seconds > 0 else { return stat }
        // A process born since the last sample accrued everything inside this interval.
        let before = lastProcesses[identity.key]
            ?? (identity.startDate > lastSampleDate ? ProcessCounters() : counters)
        let cpu = counters.cpuNs.since(before.cpuNs)
        // Only package-idle wakeups: those force the CPU out of idle. Counting interrupt
        // wakeups as well overstated drivers like AppleCentauriAlpha by ~34 against `top`.
        let wakeups = counters.idleWakeups.since(before.idleWakeups)
        let read = counters.diskRead.since(before.diskRead)
        let written = counters.diskWrite.since(before.diskWrite)

        stat.cpuPercent = Double(cpu) / intervalNs * 100
        stat.idleWakeups = Double(counters.idleWakeups.since(before.idleWakeups)) / seconds
        stat.diskReadRate = Double(read) / seconds
        stat.diskWriteRate = Double(written) / seconds
        stat.watts = Double(counters.energyNJ.since(before.energyNJ)) / 1e9 / seconds
        stat.energyImpact = energy.impact(
            cpuNs: cpu, backgroundCpuNs: counters.backgroundCpuNs.since(before.backgroundCpuNs),
            wakeups: wakeups, bytesRead: read, bytesWritten: written, seconds: seconds)
        return stat
    }

    // MARK: Groups

    private func makeGroup(coalition: UInt64, members: [RawProcess], stats: [ProcessStat], census: Census,
                           windows: [pid_t: WindowCount], seconds: Double, intervalNs: Double) -> AppGroup {
        let app = members
            .compactMap { census.apps[$0.identity.pid] }
            .min { rank($0.policy) != rank($1.policy) ? rank($0.policy) < rank($1.policy) : $0.pid < $1.pid }

        let leader = leaderProcess(members, appPID: app?.pid)
        let bundlePath = app?.bundlePath ?? Self.outermostBundle(leader.identity.path)
        let bundle = bundlePath.map(bundleDetails)
        let bundleID = app?.bundleID ?? bundle?.id
        let isOwn = members.contains { $0.identity.uid == ownUID }

        let kind: GroupKind
        switch app?.policy {
        case .regular: kind = .app
        // Dock, loginwindow and Control Center are accessory apps too, but they're macOS.
        case .accessory: kind = Self.isSystemPath(leader.identity.path) ? .system : .menuBar
        default:
            if !isOwn || Self.isSystemPath(leader.identity.path) { kind = .system }
            else { kind = .background }
        }

        let name = app?.name ?? bundle?.name ?? leader.identity.executableName
        var group = AppGroup(
            id: coalition, name: name, kind: kind, bundleID: bundleID, bundlePath: bundlePath,
            appPID: app?.pid, leaderPID: leader.identity.pid,
            historyKey: bundleID ?? (leader.identity.path.isEmpty ? name : leader.identity.path),
            processes: stats, isOwn: isOwn)

        for stat in stats {
            if let memory = stat.memory { group.memory += memory }
            if stat.memoryIsEstimate { group.memoryIsEstimate = true }
            group.realMemory += stat.realMemory ?? 0
            group.threads += stat.threads ?? 0
            group.sleepAssertions.append(contentsOf: stat.sleepAssertions)
            let count = windows[stat.pid]
            group.windows += count?.total ?? 0
            group.onscreenWindows += count?.onscreen ?? 0
        }

        if seconds > 0, let before = lastCoalitions[coalition], let now = currentCoalitions[coalition] {
            let cpu = now.cpuNs.since(before.cpuNs)
            let read = now.diskRead.since(before.diskRead)
            let written = now.diskWrite.since(before.diskWrite)
            let wakeups = now.idleWakeups.since(before.idleWakeups)
            group.cpuPercent = Double(cpu) / intervalNs * 100
            group.gpuPercent = Double(now.gpuNs.since(before.gpuNs)) / intervalNs * 100
            group.idleWakeups = Double(now.idleWakeups.since(before.idleWakeups)) / seconds
            group.diskReadRate = Double(read) / seconds
            group.diskWriteRate = Double(written) / seconds
            group.watts = Double(now.energyNJ.since(before.energyNJ)) / 1e9 / seconds
            group.spawnsPerMinute = Double(now.tasksStarted.since(before.tasksStarted)) / seconds * 60
            group.energyImpact = energy.impact(
                cpuNs: cpu, backgroundCpuNs: now.backgroundCpuNs.since(before.backgroundCpuNs),
                wakeups: wakeups, bytesRead: read, bytesWritten: written, seconds: seconds)
        } else {
            // New coalition: nothing to diff against yet, so fall back to the members.
            for stat in stats {
                group.cpuPercent += stat.cpuPercent ?? 0
                group.idleWakeups += stat.idleWakeups ?? 0
                group.diskReadRate += stat.diskReadRate ?? 0
                group.diskWriteRate += stat.diskWriteRate ?? 0
                group.energyImpact += stat.energyImpact ?? 0
                group.watts += stat.watts ?? 0
            }
        }

        if let now = currentCoalitions[coalition] {
            group.cpuSeconds = Double(now.cpuNs) / 1e9
            group.gpuSeconds = Double(now.gpuNs) / 1e9
            group.diskReadTotal = now.diskRead
            group.diskWriteTotal = now.diskWrite
            group.processesStarted = now.tasksStarted
        } else {
            group.cpuSeconds = stats.reduce(0) { $0 + ($1.cpuSeconds ?? 0) }
        }

        // A coalition with a single member: its per-process figures are the coalition's,
        // which fills in CPU and energy for root daemons whose own counters are unreadable.
        if stats.count == 1, !stats[0].isOwn {
            group.processes[0].cpuPercent = group.cpuPercent
            group.processes[0].cpuSeconds = group.cpuSeconds
            group.processes[0].energyImpact = group.energyImpact
            group.processes[0].idleWakeups = group.idleWakeups
            group.processes[0].diskReadRate = group.diskReadRate
            group.processes[0].diskWriteRate = group.diskWriteRate
            group.processes[0].watts = group.watts
        }

        if let app {
            group.isHidden = app.isHidden
            group.isActive = app.isActive
            group.launchDate = app.launchDate
        } else {
            group.launchDate = leader.identity.startDate
        }
        group.lastActive = census.lastActive[group.historyKey]
        group.hiddenSince = app?.isHidden == true ? census.hiddenSince[group.historyKey] : nil
        return group
    }


    private func leaderProcess(_ members: [RawProcess], appPID: pid_t?) -> RawProcess {
        if let appPID, let app = members.first(where: { $0.identity.pid == appPID }) { return app }
        let pids = Set(members.map(\.identity.pid))
        let responsible = members.map(\.identity.responsiblePID).filter { pids.contains($0) }
        if let common = Dictionary(grouping: responsible, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key,
           let process = members.first(where: { $0.identity.pid == common }) {
            return process
        }
        return members.min { $0.identity.startDate < $1.identity.startDate }!
    }

    private func rank(_ policy: NSApplication.ActivationPolicy) -> Int {
        switch policy {
        case .regular: 0
        case .accessory: 1
        default: 2
        }
    }

    private func userName(_ uid: uid_t) -> String {
        if let cached = userNames[uid] { return cached }
        let name = getpwuid(uid).flatMap { String(cString: $0.pointee.pw_name) } ?? String(uid)
        userNames[uid] = name
        return name
    }

    private func bundleDetails(_ path: String) -> (name: String?, id: String?) {
        if let cached = bundleInfo[path] { return cached }
        let bundle = Bundle(path: path)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let details = (name, bundle?.bundleIdentifier)
        bundleInfo[path] = details
        return details
    }

    /// "/Applications/Foo.app/Contents/Frameworks/Bar.app/Contents/MacOS/Bar" → "/Applications/Foo.app".
    static func outermostBundle(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    static func isSystemPath(_ path: String) -> Bool {
        path.isEmpty || ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/var/"].contains { path.hasPrefix($0) }
    }
}
