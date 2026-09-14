import AppKit

/// `BURN_DUMP=1 ./build/Burn.app/Contents/MacOS/Burn` prints one sample as text.
/// Used to check figures against `top` and Activity Monitor without the UI.
@MainActor
enum DumpMode {
    static func run(seconds: Double) {
        let tracker = ActivityTracker(defaults: UserDefaults(suiteName: "com.sikaihuang.Burn.dump") ?? .standard)
        let builder = SnapshotBuilder()
        _ = builder.build(census: tracker.census())
        Thread.sleep(forTimeInterval: seconds)
        let snap = builder.build(census: tracker.census())

        let s = snap.system
        print(String(format: "interval %.2fs  groups %d  processes %d  threads %d", snap.interval, snap.groups.count, s.processCount, s.threadCount))
        print(String(format: "CPU user %.1f%% sys %.1f%% idle %.1f%%  cores %@", s.cpuUser, s.cpuSystem, s.cpuIdle,
                     s.coreLoads.map { String(format: "%.0f", $0) }.joined(separator: " ")))
        print("Memory used \(gb(s.usedMemory)) (app \(gb(s.appMemory)) wired \(gb(s.wiredMemory)) compressed \(gb(s.compressedMemory))) cached \(gb(s.cachedFiles)) swap \(gb(s.swapUsed))/\(gb(s.swapTotal)) pressure \(s.pressure) \(Int(s.pressurePercent))%")
        print(String(format: "Disk R %.0f KB/s W %.0f KB/s   Net in %.0f KB/s out %.0f KB/s   GPU %@   Power %@   Thermal %d",
                     s.diskReadRate / 1024, s.diskWriteRate / 1024, s.networkInRate / 1024, s.networkOutRate / 1024,
                     s.gpuUtilization.map { String(format: "%.0f%%", $0) } ?? "-",
                     s.systemWatts.map { String(format: "%.1f W", $0) } ?? "-", s.thermal.rawValue))
        if let b = s.battery {
            print("Battery \(b.percent)% charging=\(b.isCharging) external=\(b.onExternalPower) remaining=\(b.minutesRemaining.map(String.init) ?? "-") health=\(b.health.map { String(format: "%.0f%%", $0 * 100) } ?? "-")")
        }
        let groupCPU = snap.groups.reduce(0) { $0 + $1.cpuPercent }
        let memberCPU = snap.groups.reduce(0) { total, g in total + g.processes.reduce(0) { $0 + ($1.cpuPercent ?? 0) } }
        print(String(format: "Σ group CPU %.0f%%  Σ member CPU %.0f%%  system CPU %.0f%% (%d cores)",
                     groupCPU, memberCPU, (s.cpuUser + s.cpuSystem) * Double(s.coreLoads.count), s.coreLoads.count))
        print("")
        let header = "NAME                              KIND        PROCS   CPU%  mCPU%   GPU%     MEMORY  ENERGY  WATTS mWATTS  IDLEWK  WIN  HIDDEN"
        print(header)
        for g in snap.groups.sorted(by: { $0.cpuPercent > $1.cpuPercent }).prefix(Int(environment["BURN_DUMP_ROWS"] ?? "") ?? 30) {
            // mCPU / mWATTS: the same figures summed over live members, to check the coalition totals.
            let memberCPU = g.processes.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
            let memberWatts = g.processes.reduce(0) { $0 + ($1.watts ?? 0) }
            print(pad(g.name, 33) + " " + pad(g.kind.label, 10) + String(format: " %6d %6.1f %6.1f %6.1f ", g.processes.count, g.cpuPercent, memberCPU, g.gpuPercent)
                  + pad((g.memoryIsEstimate ? "~" : "") + gb(g.memory), 10, right: true)
                  + String(format: " %7.1f %6.2f %6.2f %7.0f %4d  ", g.energyImpact, g.watts, memberWatts, g.idleWakeups, g.windows)
                  + (g.isHidden ? "hidden" : ""))
        }

        if environment["BURN_DUMP_PROCESSES"] != nil {
            print("\nPID     CPU%   ENERGY  IDLEWK   MEMORY  NAME")
            let all = snap.groups.flatMap(\.processes).filter { $0.cpuPercent != nil }
            for p in all.sorted(by: { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }).prefix(25) {
                print(String(format: "%-7d %5.1f %8.1f %7.0f %8@  %@", p.pid, p.cpuPercent ?? 0, p.energyImpact ?? 0, p.idleWakeups ?? 0,
                             gb(p.memory ?? 0) as NSString, p.name as NSString))
            }
        }
    }

    private static func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        let cut = String(text.prefix(width))
        let fill = String(repeating: " ", count: max(0, width - cut.count))
        return right ? fill + cut : cut + fill
    }

    private static func gb(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        let gib = 1_073_741_824.0
        if value >= gib { return String(format: "%.2f GB", value / gib) }
        return String(format: "%.0f MB", value / 1_048_576)
    }
}
