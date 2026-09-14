import Charts
import SwiftUI

/// The whole-Mac panel under the table, one layout per tab, like Activity Monitor's.
struct SystemFooter: View {
    let tab: ViewTab
    let system: SystemStats
    let history: [SystemPoint]

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            switch tab {
            case .cpu: cpu
            case .memory: memory
            case .energy: energy
            case .disk: disk
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(height: 118)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Tabs

    @ViewBuilder private var cpu: some View {
        Stats(items: [
            ("System", Format.percent(system.cpuSystem), .red),
            ("User", Format.percent(system.cpuUser), .blue),
            ("Idle", Format.percent(system.cpuIdle), nil)
        ])
        Graph(title: "CPU Load") {
            // Two named series with explicit bands; unnamed marks get joined point to
            // point across both layers and draw a zigzag.
            ForEach(history, id: \.date) { point in
                AreaMark(x: .value("Time", point.date), yStart: .value("Load", 0), yEnd: .value("Load", point.cpuSystem),
                         series: .value("Kind", "System"))
                    .foregroundStyle(Color.red.opacity(0.75))
                AreaMark(x: .value("Time", point.date), yStart: .value("Load", point.cpuSystem),
                         yEnd: .value("Load", point.cpuSystem + point.cpuUser), series: .value("Kind", "User"))
                    .foregroundStyle(Color.blue.opacity(0.55))
            }
        }
        .chartYScale(domain: 0...100)
        CoreBars(loads: system.coreLoads)
        Stats(items: [
            ("Processes", "\(system.processCount)", nil),
            ("Threads", "\(system.threadCount)", nil),
            ("Load avg", system.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "), nil)
        ])
    }

    @ViewBuilder private var memory: some View {
        Graph(title: "Memory Pressure") {
            ForEach(history, id: \.date) { point in
                AreaMark(x: .value("Time", point.date), y: .value("Pressure", point.pressurePercent))
                    .foregroundStyle(point.pressure.color.opacity(0.7))
            }
        }
        .chartYScale(domain: 0...100)
        Stats(items: [
            ("Physical Memory", Format.bytes(system.physicalMemory), nil),
            ("Memory Used", Format.bytes(system.usedMemory), nil),
            ("Cached Files", Format.bytes(system.cachedFiles), nil),
            ("Swap Used", Format.bytes(system.swapUsed), system.swapUsed > system.physicalMemory / 2 ? .orange : nil)
        ])
        Stats(items: [
            ("App Memory", Format.bytes(system.appMemory), nil),
            ("Wired Memory", Format.bytes(system.wiredMemory), nil),
            ("Compressed", Format.bytes(system.compressedMemory), nil),
            ("Swapping", swapActivity, system.swapOutsPerSecond > 50 ? .orange : nil)
        ])
    }

    @ViewBuilder private var energy: some View {
        Graph(title: "Power Draw (W)") {
            ForEach(history.filter { $0.watts != nil }, id: \.date) { point in
                AreaMark(x: .value("Time", point.date), y: .value("Watts", point.watts ?? 0))
                    .foregroundStyle(Color.orange.opacity(0.6))
            }
        }
        if let battery = system.battery {
            Stats(items: [
                ("Battery", "\(battery.percent)%", battery.percent <= 20 && !battery.onExternalPower ? .red : nil),
                ("Status", batteryStatus(battery), nil),
                ("Time Remaining", battery.minutesRemaining.map { Format.duration(Double($0) * 60) } ?? (battery.onExternalPower ? "On power" : "Calculating"), nil)
            ])
            Stats(items: [
                ("Power Draw", Format.watts(system.systemWatts), nil),
                ("Battery Health", battery.health.map { Format.percent($0 * 100, digits: 0) } ?? "—", nil),
                ("Cycle Count", battery.cycleCount.map(String.init) ?? "—", nil)
            ])
        } else {
            Stats(items: [("Power Draw", Format.watts(system.systemWatts), nil)])
        }
        Stats(items: [
            ("Thermal State", system.thermal.label, system.thermal.rawValue >= 2 ? .orange : nil),
            ("GPU", Format.percent(system.gpuUtilization, digits: 0), nil)
        ])
    }

    @ViewBuilder private var disk: some View {
        Stats(items: [
            ("Reads /s", Format.number(system.diskReadOpsRate, digits: 0), .blue),
            ("Writes /s", Format.number(system.diskWriteOpsRate, digits: 0), .red)
        ])
        Graph(title: "Data (read / written)") {
            ForEach(history, id: \.date) { point in
                LineMark(x: .value("Time", point.date), y: .value("Bytes", point.diskRead), series: .value("Kind", "Read"))
                    .foregroundStyle(Color.blue)
                LineMark(x: .value("Time", point.date), y: .value("Bytes", point.diskWrite), series: .value("Kind", "Write"))
                    .foregroundStyle(Color.red)
            }
        }
        Stats(items: [
            ("Data Read /s", Format.rate(system.diskReadRate), .blue),
            ("Data Written /s", Format.rate(system.diskWriteRate), .red)
        ])
        Stats(items: [
            ("Network In /s", Format.rate(system.networkInRate), nil),
            ("Network Out /s", Format.rate(system.networkOutRate), nil)
        ])
    }

    private var swapActivity: String {
        let pages = system.swapInsPerSecond + system.swapOutsPerSecond
        return pages < 1 ? "Idle" : String(format: "%.0f pages/s", pages)
    }

    private func batteryStatus(_ battery: BatteryState) -> String {
        if battery.isCharging { return "Charging" }
        if battery.onExternalPower { return battery.fullyCharged ? "Charged" : "On power, not charging" }
        return "On battery"
    }
}

private struct Stats: View {
    let items: [(String, String, Color?)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(items, id: \.0) { item in
                GridRow {
                    Text(item.0).foregroundStyle(.secondary)
                    Text(item.1)
                        .monospacedDigit()
                        .fontWeight(.medium)
                        .foregroundStyle(item.2 ?? .primary)
                        .gridColumnAlignment(.trailing)
                }
            }
        }
        .font(.callout)
        .fixedWidth()
    }
}

private struct Graph<Content: ChartContent>: View {
    let title: String
    @ChartContentBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Chart { content() }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        }
        .frame(minWidth: 180, maxWidth: 320)
    }
}

private struct CoreBars: View {
    let loads: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cores").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(loads.enumerated()), id: \.offset) { _, load in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                        RoundedRectangle(cornerRadius: 2).fill(load > 85 ? Color.orange : Color.accentColor)
                            .frame(height: max(2, 70 * load / 100))
                    }
                    .frame(width: 8, height: 70)
                }
            }
        }
        .fixedWidth()
    }
}

extension View {
    func fixedWidth() -> some View { fixedSize(horizontal: true, vertical: false) }
}

extension PressureLevel {
    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}
