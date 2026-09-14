import CProc
import Darwin
import Foundation

/// A pid is reused after a process exits, so pid + start time is the real identity.
struct ProcessKey: Hashable {
    let pid: pid_t
    let startMicros: UInt64
}

/// Facts fixed for the life of a process. Read once, then cached.
struct ProcessIdentity {
    let key: ProcessKey
    let ppid: pid_t
    let uid: uid_t
    let executableName: String
    let path: String
    let startDate: Date
    let resourceCoalition: UInt64
    let jetsamCoalition: UInt64
    let responsiblePID: pid_t

    var pid: pid_t { key.pid }
}

/// Cumulative counters for one process. Only readable for the current user's
/// processes; the kernel refuses them for root and other users without privilege.
struct ProcessCounters {
    var cpuNs: UInt64 = 0
    var backgroundCpuNs: UInt64 = 0
    var footprint: UInt64 = 0
    var resident: UInt64 = 0
    var threads: Int = 0
    var idleWakeups: UInt64 = 0
    var interruptWakeups: UInt64 = 0
    var diskRead: UInt64 = 0
    var diskWrite: UInt64 = 0
    var energyNJ: UInt64 = 0
}

/// Cumulative counters for a whole coalition, including members that have exited.
/// Readable for every coalition without privilege.
struct CoalitionCounters {
    var cpuNs: UInt64 = 0
    var backgroundCpuNs: UInt64 = 0
    var energyNJ: UInt64 = 0
    var gpuNs: UInt64 = 0
    var diskRead: UInt64 = 0
    var diskWrite: UInt64 = 0
    var idleWakeups: UInt64 = 0
    var interruptWakeups: UInt64 = 0
    var tasksStarted: UInt64 = 0
    var tasksExited: UInt64 = 0
}

struct RawProcess {
    let identity: ProcessIdentity
    let counters: ProcessCounters?
}

struct RawProcessSample {
    let processes: [RawProcess]
    let coalitions: [UInt64: CoalitionCounters]
    let threadCount: Int
}

final class ProcessSampler {
    private var identities: [ProcessKey: ProcessIdentity] = [:]
    private let ownUID = getuid()

    func sample() -> RawProcessSample {
        let kinfos = Self.listKernelProcesses()
        var processes: [RawProcess] = []
        processes.reserveCapacity(kinfos.count)
        var seen = Set<ProcessKey>()
        var coalitionIDs = Set<UInt64>()
        var threads = 0

        for kp in kinfos {
            let pid = kp.kp_proc.p_pid
            // Zombies have exited and hold nothing; pid 0 is the kernel, charged via its coalition.
            if kp.kp_proc.p_stat == CChar(SZOMB) { continue }
            let start = kp.kp_proc.p_un.__p_starttime
            let key = ProcessKey(pid: pid, startMicros: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec))
            seen.insert(key)

            let identity: ProcessIdentity
            if let cached = identities[key] {
                identity = cached
            } else {
                guard let fresh = makeIdentity(kp, key: key) else { continue }
                identities[key] = fresh
                identity = fresh
            }
            coalitionIDs.insert(identity.resourceCoalition)

            let counters = identity.uid == ownUID ? Self.readCounters(pid) : nil
            threads += counters?.threads ?? 0
            processes.append(RawProcess(identity: identity, counters: counters))
        }

        identities = identities.filter { seen.contains($0.key) }

        var coalitions: [UInt64: CoalitionCounters] = [:]
        for id in coalitionIDs where id != 0 {
            if let c = Self.readCoalition(id) { coalitions[id] = c }
        }
        return RawProcessSample(processes: processes, coalitions: coalitions, threadCount: threads)
    }

    private func makeIdentity(_ kp: kinfo_proc, key: ProcessKey) -> ProcessIdentity? {
        let pid = key.pid
        var resource: UInt64 = 0
        var jetsam: UInt64 = 0
        _ = burn_coalition_ids_for_pid(pid, &resource, &jetsam)

        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : ""
        let comm = stringFromCTuple(kp.kp_proc.p_comm)
        // p_comm is cut at 16 characters ("Google Chrome He"); the path has the full name.
        let name = path.isEmpty ? (pid == 0 ? "kernel_task" : comm) : (path as NSString).lastPathComponent

        let start = kp.kp_proc.p_un.__p_starttime
        return ProcessIdentity(
            key: key,
            ppid: kp.kp_eproc.e_ppid,
            uid: kp.kp_eproc.e_ucred.cr_uid,
            executableName: name,
            path: path,
            startDate: Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1e6),
            resourceCoalition: resource,
            jetsamCoalition: jetsam,
            responsiblePID: burn_responsible_pid(pid)
        )
    }

    private static func readCounters(_ pid: pid_t) -> ProcessCounters? {
        var usage = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard rc == 0 else { return nil }

        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let haveTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize

        let background = usage.ri_cpu_time_qos_background + usage.ri_cpu_time_qos_maintenance
        return ProcessCounters(
            cpuNs: Clock.nanoseconds(machUnits: usage.ri_user_time + usage.ri_system_time),
            backgroundCpuNs: Clock.nanoseconds(machUnits: background),
            footprint: usage.ri_phys_footprint,
            resident: haveTask ? task.pti_resident_size : usage.ri_resident_size,
            threads: haveTask ? Int(task.pti_threadnum) : 0,
            idleWakeups: usage.ri_pkg_idle_wkups,
            interruptWakeups: usage.ri_interrupt_wkups,
            diskRead: usage.ri_diskio_bytesread,
            diskWrite: usage.ri_diskio_byteswritten,
            energyNJ: usage.ri_energy_nj
        )
    }

    private static func readCoalition(_ id: UInt64) -> CoalitionCounters? {
        var usage = burn_coalition_usage()
        guard burn_coalition_usage(id, &usage) == 1 else { return nil }
        // Effective-QoS buckets: 1 maintenance, 2 background.
        let background = usage.cpu_time_eqos.1 + usage.cpu_time_eqos.2
        return CoalitionCounters(
            cpuNs: Clock.nanoseconds(machUnits: usage.cpu_time),
            backgroundCpuNs: Clock.nanoseconds(machUnits: background),
            energyNJ: usage.energy,
            gpuNs: usage.gpu_time,
            diskRead: usage.bytesread,
            diskWrite: usage.byteswritten,
            idleWakeups: usage.platform_idle_wakeups,
            interruptWakeups: usage.interrupt_wakeups,
            tasksStarted: usage.tasks_started,
            tasksExited: usage.tasks_exited
        )
    }

    private static func listKernelProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
            size += size / 8
            var list = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
            var filled = list.count * stride
            let rc = list.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &filled, nil, 0) }
            if rc == 0 { return Array(list.prefix(filled / stride)) }
            if errno != ENOMEM { return [] }
        }
        return []
    }
}
