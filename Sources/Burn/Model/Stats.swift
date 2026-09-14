import Foundation

enum GroupKind: Int, Comparable, CaseIterable {
    /// A regular app with a Dock icon.
    case app
    /// A menu bar app or agent from an app bundle.
    case menuBar
    /// The user's own background work outside any app: updaters, CLI tools, agents.
    case background
    /// macOS itself and daemons owned by root or other system users.
    case system

    static func < (a: GroupKind, b: GroupKind) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .app: "App"
        case .menuBar: "Menu bar"
        case .background: "Background"
        case .system: "System"
        }
    }
}

struct ProcessStat: Identifiable {
    var id: ProcessKey { identity.key }
    let identity: ProcessIdentity
    let name: String
    let user: String
    /// Owned by the current user, so every counter is readable and signals need no admin.
    let isOwn: Bool

    var cpuPercent: Double?
    var cpuSeconds: Double?
    var memory: UInt64?
    /// Memory is resident size standing in for footprint (other users' processes).
    var memoryIsEstimate = false
    var realMemory: UInt64?
    var threads: Int?
    var idleWakeups: Double?
    var energyImpact: Double?
    var watts: Double?
    var diskReadRate: Double?
    var diskWriteRate: Double?
    var diskReadTotal: UInt64?
    var diskWriteTotal: UInt64?
    var sleepAssertions: [SleepAssertion] = []

    var pid: pid_t { identity.pid }
}

struct AppGroup: Identifiable {
    /// The resource coalition id, unique for this boot.
    let id: UInt64
    var name: String
    var kind: GroupKind
    var bundleID: String?
    var bundlePath: String?
    /// The NSRunningApplication's pid when this group is a real app.
    var appPID: pid_t?
    var leaderPID: pid_t
    /// Stable across relaunches and reboots; history is stored under it.
    var historyKey: String
    var processes: [ProcessStat] = []
    var isOwn = true

    var cpuPercent = 0.0
    var cpuSeconds = 0.0
    var gpuPercent = 0.0
    var gpuSeconds = 0.0
    var memory: UInt64 = 0
    var memoryIsEstimate = false
    var realMemory: UInt64 = 0
    var threads = 0
    var idleWakeups = 0.0
    var energyImpact = 0.0
    var watts = 0.0
    var diskReadRate = 0.0
    var diskWriteRate = 0.0
    var diskReadTotal: UInt64 = 0
    var diskWriteTotal: UInt64 = 0
    var processesStarted: UInt64 = 0
    var spawnsPerMinute = 0.0

    var isHidden = false
    var isActive = false
    var windows = 0
    var onscreenWindows = 0
    var launchDate: Date?
    var lastActive: Date?
    var hiddenSince: Date?
    var sleepAssertions: [SleepAssertion] = []
}

struct Snapshot {
    var date = Date()
    /// Seconds covered by the rates in this snapshot. Zero for the very first one.
    var interval = 0.0
    var groups: [AppGroup] = []
    var system = SystemStats()
    var trackingSince = Date()

    static let empty = Snapshot()
}
