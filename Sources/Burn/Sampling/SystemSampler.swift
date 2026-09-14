import CProc
import Darwin
import Foundation
import IOKit

enum PressureLevel: Int, Comparable {
    case normal = 1, warning = 2, critical = 4

    static func < (a: PressureLevel, b: PressureLevel) -> Bool { a.rawValue < b.rawValue }
}

struct BatteryState {
    var percent: Int
    var isCharging: Bool
    var onExternalPower: Bool
    var fullyCharged: Bool
    /// nil while macOS is still estimating (it reports 65535).
    var minutesRemaining: Int?
    /// Watts flowing out of the battery; nil on AC.
    var dischargeWatts: Double?
    var cycleCount: Int?
    /// Current full-charge capacity as a share of design capacity.
    var health: Double?
    /// Energy a full charge holds today, for turning watts into battery percent.
    var capacityWh: Double?
}

struct SystemStats {
    var cpuUser = 0.0
    var cpuSystem = 0.0
    var cpuIdle = 100.0
    var coreLoads: [Double] = []
    var loadAverage: [Double] = [0, 0, 0]
    var processCount = 0
    var threadCount = 0

    var physicalMemory: UInt64 = 0
    var appMemory: UInt64 = 0
    var wiredMemory: UInt64 = 0
    var compressedMemory: UInt64 = 0
    var cachedFiles: UInt64 = 0
    var freeMemory: UInt64 = 0
    var usedMemory: UInt64 { appMemory + wiredMemory + compressedMemory }
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapInsPerSecond = 0.0
    var swapOutsPerSecond = 0.0
    var pressure: PressureLevel = .normal
    /// Activity Monitor's pressure graph: 100 minus the kernel's free-memory level.
    var pressurePercent = 0.0

    var diskReadRate = 0.0
    var diskWriteRate = 0.0
    var diskReadOpsRate = 0.0
    var diskWriteOpsRate = 0.0
    var networkInRate = 0.0
    var networkOutRate = 0.0
    var packetsInRate = 0.0
    var packetsOutRate = 0.0

    var gpuUtilization: Double?
    /// Whole-Mac power draw from the battery gauge's telemetry.
    var systemWatts: Double?
    var battery: BatteryState?
    var thermal: ProcessInfo.ThermalState = .nominal
    var bootDate = Date()
}

final class SystemSampler {
    private let host = mach_host_self()
    private let batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    private let gpuService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
    private var lastTime: UInt64 = 0
    private var lastCoreTicks: [[UInt64]] = []
    private var lastDisk: [UInt64] = []
    private var lastNetwork: [UInt64] = []
    private var lastSwap: [UInt64] = []

    func sample() -> SystemStats {
        let now = Clock.uptimeNs()
        let seconds = lastTime == 0 ? 0 : Double(now - lastTime) / 1e9
        var stats = SystemStats()

        sampleCPU(&stats)
        sampleMemory(&stats, seconds: seconds)
        sampleDisk(&stats, seconds: seconds)
        sampleNetwork(&stats, seconds: seconds)
        sampleBattery(&stats)
        stats.gpuUtilization = gpuUtilization()
        stats.thermal = ProcessInfo.processInfo.thermalState

        var averages = [Double](repeating: 0, count: 3)
        if getloadavg(&averages, 3) == 3 { stats.loadAverage = averages }
        // kern.num_tasks / kern.num_threads are limits, not counts. The default processor
        // set reports the live totals without privilege.
        var load = processor_set_load_info()
        var loadCount = mach_msg_type_number_t(MemoryLayout<processor_set_load_info>.stride / MemoryLayout<integer_t>.stride)
        var processorSet: processor_set_name_t = 0
        if processor_set_default(host, &processorSet) == KERN_SUCCESS {
            let kr = withUnsafeMutablePointer(to: &load) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(loadCount)) {
                    processor_set_statistics(processorSet, PROCESSOR_SET_LOAD_INFO, $0, &loadCount)
                }
            }
            if kr == KERN_SUCCESS {
                stats.processCount = Int(load.task_count)
                stats.threadCount = Int(load.thread_count)
            }
            mach_port_deallocate(mach_task_self_, processorSet)
        }
        let boot = sysctlValue("kern.boottime", default: timeval())
        stats.bootDate = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))

        lastTime = now
        return stats
    }

    // MARK: CPU

    private func sampleCPU(_ stats: inout SystemStats) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var ticks: [[UInt64]] = []
        for core in 0..<Int(cpuCount) {
            let base = core * Int(CPU_STATE_MAX)
            ticks.append([CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE].map {
                UInt64(UInt32(bitPattern: info[base + Int($0)]))
            })
        }
        defer { lastCoreTicks = ticks }
        guard lastCoreTicks.count == ticks.count else { return }

        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0
        var loads: [Double] = []
        for (now, before) in zip(ticks, lastCoreTicks) {
            let u = now[0].since(before[0]) + now[3].since(before[3])
            let s = now[1].since(before[1])
            let i = now[2].since(before[2])
            user += u; system += s; idle += i
            let total = u + s + i
            loads.append(total == 0 ? 0 : Double(u + s) / Double(total) * 100)
        }
        let total = Double(user + system + idle)
        guard total > 0 else { return }
        stats.cpuUser = Double(user) / total * 100
        stats.cpuSystem = Double(system) / total * 100
        stats.cpuIdle = Double(idle) / total * 100
        stats.coreLoads = loads
    }

    // MARK: Memory

    private func sampleMemory(_ stats: inout SystemStats, seconds: Double) {
        stats.physicalMemory = sysctlValue("hw.memsize", default: UInt64(0))

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            // Activity Monitor's definitions, so the numbers line up with it.
            stats.appMemory = UInt64(vm.internal_page_count).since(UInt64(vm.purgeable_count)) * page
            stats.wiredMemory = UInt64(vm.wire_count) * page
            stats.compressedMemory = UInt64(vm.compressor_page_count) * page
            stats.cachedFiles = (UInt64(vm.external_page_count) + UInt64(vm.purgeable_count)) * page
            stats.freeMemory = (UInt64(vm.free_count) + UInt64(vm.speculative_count)) * page

            let swap = [vm.swapins, vm.swapouts]
            if lastSwap.count == 2, seconds > 0 {
                stats.swapInsPerSecond = Double(swap[0].since(lastSwap[0])) / seconds
                stats.swapOutsPerSecond = Double(swap[1].since(lastSwap[1])) / seconds
            }
            lastSwap = swap
        }

        let swap = sysctlValue("vm.swapusage", default: xsw_usage())
        stats.swapUsed = swap.xsu_used
        stats.swapTotal = swap.xsu_total

        let level = sysctlValue("kern.memorystatus_vm_pressure_level", default: Int32(1))
        stats.pressure = PressureLevel(rawValue: Int(level)) ?? (level > 2 ? .critical : .normal)
        let freeLevel = sysctlValue("kern.memorystatus_level", default: Int32(100))
        stats.pressurePercent = Double(max(0, min(100, 100 - freeLevel)))
    }

    // MARK: Disk and network

    private func sampleDisk(_ stats: inout SystemStats, seconds: Double) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var totals: [UInt64] = [0, 0, 0, 0]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let dict = registryValue(entry, "Statistics") as? [String: Any] else { continue }
            for (i, key) in ["Bytes (Read)", "Bytes (Write)", "Operations (Read)", "Operations (Write)"].enumerated() {
                totals[i] += (dict[key] as? NSNumber)?.uint64Value ?? 0
            }
        }
        if lastDisk.count == 4, seconds > 0 {
            stats.diskReadRate = Double(totals[0].since(lastDisk[0])) / seconds
            stats.diskWriteRate = Double(totals[1].since(lastDisk[1])) / seconds
            stats.diskReadOpsRate = Double(totals[2].since(lastDisk[2])) / seconds
            stats.diskWriteOpsRate = Double(totals[3].since(lastDisk[3])) / seconds
        }
        lastDisk = totals
    }

    private func sampleNetwork(_ stats: inout SystemStats, seconds: Double) {
        var bytesIn: UInt64 = 0, bytesOut: UInt64 = 0, packetsIn: UInt64 = 0, packetsOut: UInt64 = 0
        guard burn_network_totals(&bytesIn, &bytesOut, &packetsIn, &packetsOut) == 1 else { return }
        let totals = [bytesIn, bytesOut, packetsIn, packetsOut]
        if lastNetwork.count == 4, seconds > 0 {
            stats.networkInRate = Double(totals[0].since(lastNetwork[0])) / seconds
            stats.networkOutRate = Double(totals[1].since(lastNetwork[1])) / seconds
            stats.packetsInRate = Double(totals[2].since(lastNetwork[2])) / seconds
            stats.packetsOutRate = Double(totals[3].since(lastNetwork[3])) / seconds
        }
        lastNetwork = totals
    }

    // MARK: Power

    private func sampleBattery(_ stats: inout SystemStats) {
        guard batteryService != 0 else { return }
        func number(_ key: String) -> NSNumber? { registryValue(batteryService, key) as? NSNumber }
        func flag(_ key: String) -> Bool { (registryValue(batteryService, key) as? Bool) ?? false }

        if let telemetry = registryValue(batteryService, "PowerTelemetryData") as? [String: Any],
           let load = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue, load > 0 {
            stats.systemWatts = load / 1000
        }

        guard let percent = number("CurrentCapacity")?.intValue else { return }
        let external = flag("ExternalConnected")
        let remaining = number("TimeRemaining")?.intValue
        var discharge: Double?
        if !external, let amps = number("InstantAmperage")?.int64Value, let volts = number("Voltage")?.doubleValue, amps < 0 {
            discharge = Double(-amps) / 1000 * volts / 1000
        }
        var health: Double?
        var capacityWh: Double?
        if let raw = number("AppleRawMaxCapacity")?.doubleValue {
            if let design = number("DesignCapacity")?.doubleValue, design > 0 { health = raw / design }
            if let volts = number("Voltage")?.doubleValue { capacityWh = raw * volts / 1_000_000 }
        }
        stats.battery = BatteryState(
            percent: percent,
            isCharging: flag("IsCharging"),
            onExternalPower: external,
            fullyCharged: flag("FullyCharged"),
            minutesRemaining: (remaining == nil || remaining! >= 65535 || remaining! <= 0) ? nil : remaining,
            dischargeWatts: discharge,
            cycleCount: number("CycleCount")?.intValue,
            health: health,
            capacityWh: capacityWh
        )
        if stats.systemWatts == nil { stats.systemWatts = discharge }
    }

    private func gpuUtilization() -> Double? {
        guard gpuService != 0,
              let perf = registryValue(gpuService, "PerformanceStatistics") as? [String: Any],
              let value = perf["Device Utilization %"] as? NSNumber else { return nil }
        return value.doubleValue
    }

    private func registryValue(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
