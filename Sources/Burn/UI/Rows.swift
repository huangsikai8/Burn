import Foundation

enum Metric: String, CaseIterable, Identifiable, Codable {
    case cpu, cpuTime, threads, idleWakeups, gpu, gpuTime
    case memory, realMemory, memoryTrend
    case energy, watts, energyAverage, batteryToday, preventingSleep
    case diskRead, diskWrite, diskReadTotal, diskWriteTotal
    case processes, pid, user, kind, status, lastUsed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "% CPU"
        case .cpuTime: "CPU Time"
        case .threads: "Threads"
        case .idleWakeups: "Idle Wake Ups"
        case .gpu: "% GPU"
        case .gpuTime: "GPU Time"
        case .memory: "Memory"
        case .realMemory: "Real Memory"
        case .memoryTrend: "Growth /h"
        case .energy: "Energy Impact"
        case .watts: "CPU Power"
        case .energyAverage: "1 h Avg Energy"
        case .batteryToday: "Battery Today"
        case .preventingSleep: "Preventing Sleep"
        case .diskRead: "Read /s"
        case .diskWrite: "Written /s"
        case .diskReadTotal: "Bytes Read"
        case .diskWriteTotal: "Bytes Written"
        case .processes: "Processes"
        case .pid: "PID"
        case .user: "User"
        case .kind: "Kind"
        case .status: "Status"
        case .lastUsed: "Last Used"
        }
    }

    var isText: Bool {
        switch self {
        case .user, .kind, .status, .preventingSleep: true
        default: false
        }
    }

    var width: (min: CGFloat, ideal: CGFloat) {
        switch self {
        case .status: (80, 110)
        case .cpuTime, .gpuTime: (96, 104)
        case .preventingSleep, .lastUsed, .kind, .user: (56, 72)
        case .pid: (54, 60)
        case .threads, .processes, .idleWakeups: (48, 56)
        default: (60, 74)
        }
    }
}

enum ViewTab: String, CaseIterable, Identifiable {
    case cpu = "CPU", memory = "Memory", energy = "Energy", disk = "Disk"

    var id: String { rawValue }

    /// The primary metric this tab sorts by when first opened.
    var primary: Metric {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .energy: .energy
        case .disk: .diskWrite
        }
    }

    var columns: [Metric] {
        switch self {
        case .cpu: [.cpu, .cpuTime, .threads, .idleWakeups, .gpu, .processes, .status, .pid]
        case .memory: [.memory, .memoryTrend, .realMemory, .processes, .status, .lastUsed, .pid]
        case .energy: [.energy, .watts, .energyAverage, .batteryToday, .idleWakeups, .preventingSleep, .status, .pid]
        case .disk: [.diskWrite, .diskRead, .diskWriteTotal, .diskReadTotal, .processes, .status, .pid]
        }
    }
}

enum RowLevel {
    /// The "macOS & system services" roll-up.
    case section
    case group
    /// Several processes from one executable, e.g. "Renderer ×14".
    case bucket
    case process
}

enum Tone {
    case neutral, info, warning, critical
}

struct Badge: Hashable {
    let text: String
    let tone: Tone
}

/// A row of the outline. Built fresh from each snapshot; ids are stable so SwiftUI
/// keeps expansion and selection across refreshes.
struct Row: Identifiable {
    let id: String
    let level: RowLevel
    let name: String
    var detail: String?
    var group: AppGroup?
    var process: ProcessStat?
    var children: [Row]?
    var values: [Metric: Double] = [:]
    var text: [Metric: String] = [:]
    var badge: Badge?
    /// Figures that stand in for something unreadable, shown with a leading "~".
    var estimated: Set<Metric> = []

    func value(_ metric: Metric) -> Double? { values[metric] }
}

/// Figures the table shows that come from history rather than the live snapshot.
struct RowExtras {
    var memoryGrowthPerHour: [String: Double] = [:]
    var energyAverage: [String: Double] = [:]
    var batteryToday: [String: Double] = [:]
    var badges: [UInt64: Badge] = [:]
}
