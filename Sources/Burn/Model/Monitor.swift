import AppKit
import Combine

/// One point of whole-Mac history, kept in memory for the footer graphs.
struct SystemPoint {
    let date: Date
    let cpuUser: Double
    let cpuSystem: Double
    let pressurePercent: Double
    let pressure: PressureLevel
    let memoryUsed: UInt64
    let swapUsed: UInt64
    let diskRead: Double
    let diskWrite: Double
    let networkIn: Double
    let networkOut: Double
    let watts: Double?
    let gpu: Double?
}

/// One point of per-app history at sample resolution. The detectors (runaway,
/// hidden-but-busy, spikes) read these; long-term history lives in HistoryStore.
struct GroupPoint {
    let date: Date
    let cpu: Double
    let memory: UInt64
    let watts: Double
    let energy: Double
    let idleWakeups: Double
    /// Highest single-process CPU in the group, for runaway detection.
    let hottestProcessCPU: Double
    let hottestProcess: ProcessKey?
}

@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var snapshot = Snapshot.empty
    @Published private(set) var systemHistory: [SystemPoint] = []
    private(set) var groupHistory: [String: [GroupPoint]] = [:]

    let tracker: ActivityTracker
    /// When this run of Burn began sampling; "what changed" ignores apps that merely predate it.
    let trackingStart = Date()
    private let builder = SnapshotBuilder()
    private let queue = DispatchQueue(label: "com.sikaihuang.Burn.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var sampling = false
    private var subscribers: [(Snapshot) -> Void] = []

    /// Samples every 2 s while a window or the popover is open, every 10 s otherwise.
    /// Coalition counters are cumulative, so the slower cadence loses resolution but
    /// never loses work: a spike between samples still lands in the next average.
    var visibleInterval: TimeInterval = 2
    var backgroundInterval: TimeInterval = 10
    private var visibleClients = 0

    static let systemHistoryLimit = 300
    static let groupHistoryWindow: TimeInterval = 3600

    init(tracker: ActivityTracker? = nil) {
        self.tracker = tracker ?? ActivityTracker()
    }

    func start() {
        guard timer == nil else { return }
        tick()
        reschedule()
    }

    /// Call when a view that shows live numbers appears or disappears.
    func setVisible(_ visible: Bool) {
        let wasVisible = visibleClients > 0
        visibleClients = max(0, visibleClients + (visible ? 1 : -1))
        let isVisible = visibleClients > 0
        guard wasVisible != isVisible else { return }
        reschedule()
        if isVisible { tick() }
    }

    func subscribe(_ handler: @escaping (Snapshot) -> Void) {
        subscribers.append(handler)
    }

    func history(for key: String) -> [GroupPoint] {
        groupHistory[key] ?? []
    }

    private func reschedule() {
        timer?.cancel()
        let interval = visibleClients > 0 ? visibleInterval : backgroundInterval
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        source.resume()
        timer = source
    }

    private func tick() {
        guard !sampling else { return }
        sampling = true
        let census = tracker.census()
        let builder = self.builder
        queue.async { [weak self] in
            let snapshot = builder.build(census: census)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sampling = false
                    self.publish(snapshot)
                }
            }
        }
    }

    private func publish(_ snapshot: Snapshot) {
        // The first snapshot has no interval to diff, so every rate in it is zero.
        guard snapshot.interval > 0 else { return }
        self.snapshot = snapshot
        record(snapshot)
        for subscriber in subscribers { subscriber(snapshot) }
    }

    private func record(_ snapshot: Snapshot) {
        let s = snapshot.system
        systemHistory.append(SystemPoint(
            date: snapshot.date, cpuUser: s.cpuUser, cpuSystem: s.cpuSystem,
            pressurePercent: s.pressurePercent, pressure: s.pressure, memoryUsed: s.usedMemory, swapUsed: s.swapUsed,
            diskRead: s.diskReadRate, diskWrite: s.diskWriteRate, networkIn: s.networkInRate, networkOut: s.networkOutRate,
            watts: s.systemWatts, gpu: s.gpuUtilization))
        if systemHistory.count > Self.systemHistoryLimit {
            systemHistory.removeFirst(systemHistory.count - Self.systemHistoryLimit)
        }

        let cutoff = snapshot.date.addingTimeInterval(-Self.groupHistoryWindow)
        var live = Set<String>()
        for group in snapshot.groups {
            live.insert(group.historyKey)
            let hottest = group.processes.max { ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0) }
            let point = GroupPoint(
                date: snapshot.date, cpu: group.cpuPercent, memory: group.memory, watts: group.watts,
                energy: group.energyImpact, idleWakeups: group.idleWakeups,
                hottestProcessCPU: hottest?.cpuPercent ?? (group.processes.count == 1 ? group.cpuPercent : 0),
                hottestProcess: hottest?.id)
            var points = groupHistory[group.historyKey] ?? []
            // Two coalitions can share a key (two copies of a CLI tool); keep one point per sample.
            if let last = points.last, last.date == snapshot.date {
                points[points.count - 1] = GroupPoint(
                    date: last.date, cpu: last.cpu + point.cpu, memory: last.memory + point.memory,
                    watts: last.watts + point.watts, energy: last.energy + point.energy,
                    idleWakeups: last.idleWakeups + point.idleWakeups,
                    hottestProcessCPU: max(last.hottestProcessCPU, point.hottestProcessCPU),
                    hottestProcess: last.hottestProcessCPU >= point.hottestProcessCPU ? last.hottestProcess : point.hottestProcess)
            } else {
                points.append(point)
            }
            if let firstKept = points.firstIndex(where: { $0.date >= cutoff }), firstKept > 0 {
                points.removeFirst(firstKept)
            }
            groupHistory[group.historyKey] = points
        }
        groupHistory = groupHistory.filter { live.contains($0.key) }
    }
}
