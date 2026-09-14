import Darwin
import Foundation

enum Clock {
    /// Nanoseconds per Mach time unit. CPU times from libproc arrive in Mach units,
    /// which on Apple silicon are 125/3 ns — forgetting this makes CPU figures ~41x off.
    static let nsPerMachUnit: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    static func nanoseconds(machUnits: UInt64) -> UInt64 {
        UInt64(Double(machUnits) * nsPerMachUnit)
    }

    /// Monotonic time that stops while asleep, matching how CPU time accrues.
    static func uptimeNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}

extension UInt64 {
    /// Counter difference that treats a reset (new process reusing a key, reboot) as zero.
    func since(_ earlier: UInt64) -> UInt64 {
        self >= earlier ? self - earlier : 0
    }
}

/// Reads a fixed-size C char array imported as a tuple.
func stringFromCTuple<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}

func sysctlValue<T>(_ name: String, default fallback: T) -> T {
    var value = fallback
    var size = MemoryLayout<T>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : fallback
}

/// Activity Monitor's Energy Impact score, rebuilt from the same weights it reads.
///
/// The weights ship in /usr/share/pmenergy (a per-model plist on Intel, `default` on
/// Apple silicon). Reading them at runtime keeps the score in step with the OS.
struct EnergyModel {
    var cpu = 1.0
    var wakeups = 0.0002
    var diskRead = 4.5e-10
    var diskWrite = 2.4e-10
    var backgroundQoS = 0.8

    static let system: EnergyModel = {
        var model = EnergyModel()
        guard let root = NSDictionary(contentsOfFile: "/usr/share/pmenergy/default.plist"),
              let constants = root["energy_constants"] as? [String: NSNumber] else { return model }
        model.cpu = constants["kcpu_time"]?.doubleValue ?? model.cpu
        model.wakeups = constants["kcpu_wakeups"]?.doubleValue ?? model.wakeups
        model.diskRead = constants["kdiskio_bytesread"]?.doubleValue ?? model.diskRead
        model.diskWrite = constants["kdiskio_byteswritten"]?.doubleValue ?? model.diskWrite
        model.backgroundQoS = constants["kqos_background"]?.doubleValue ?? model.backgroundQoS
        return model
    }()

    /// Score per second of wall time, scaled so one fully busy core scores ~100.
    func impact(cpuNs: UInt64, backgroundCpuNs: UInt64, wakeups: UInt64,
                bytesRead: UInt64, bytesWritten: UInt64, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        let background = Double(min(backgroundCpuNs, cpuNs))
        let foreground = Double(cpuNs) - background
        let cpuSeconds = (foreground + backgroundQoS * background) / 1e9
        let score = cpu * cpuSeconds
            + self.wakeups * Double(wakeups)
            + diskRead * Double(bytesRead)
            + diskWrite * Double(bytesWritten)
        return 100 * score / seconds
    }
}
