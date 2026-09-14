import Darwin
import Foundation

/// Memory for processes owned by root and other users, which libproc won't read.
///
/// Two setuid tools can see them. `ps` reports resident size cheaply, so it runs
/// every 30 s. `top` reports the footprint Activity Monitor shows but costs
/// ~1.5 s of CPU per pass, so it runs rarely and in the background, and its values
/// replace the resident estimate for as long as they stay fresh.
final class ForeignProcessMemory {
    private(set) var resident: [pid_t: UInt64] = [:]
    private var footprint: [pid_t: UInt64] = [:]
    private var lastTop: Date = .distantPast
    private var lastPS: Date = .distantPast
    private var topRunning = false
    private let lock = NSLock()
    private let topInterval: TimeInterval
    private let psInterval: TimeInterval

    /// Spawning a process costs far more than reading counters, and resident memory of
    /// daemons moves slowly, so `ps` runs every 30 s rather than on every sample.
    init(topInterval: TimeInterval = 300, psInterval: TimeInterval = 30) {
        self.topInterval = topInterval
        self.psInterval = psInterval
        // The first exact pass waits a minute so launching Burn isn't itself a CPU spike.
        lastTop = Date().addingTimeInterval(60 - topInterval)
    }

    func refresh() {
        if Date().timeIntervalSince(lastPS) >= psInterval {
            resident = Self.runPS()
            lastPS = Date()
        }
        lock.lock()
        let due = !topRunning && Date().timeIntervalSince(lastTop) > topInterval
        if due { topRunning = true }
        lock.unlock()
        guard due else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let values = Self.runTop()
            guard let self else { return }
            self.lock.lock()
            if !values.isEmpty { self.footprint = values }
            self.lastTop = Date()
            self.topRunning = false
            self.lock.unlock()
        }
    }

    /// Footprint when `top` has reported one for this pid, otherwise resident size.
    func memory(for pid: pid_t) -> (bytes: UInt64, exact: Bool)? {
        lock.lock()
        let exact = footprint[pid]
        lock.unlock()
        if let exact { return (exact, true) }
        if let rss = resident[pid] { return (rss, false) }
        return nil
    }

    private static func runPS() -> [pid_t: UInt64] {
        guard let output = run("/bin/ps", ["-axo", "pid=,rss="]) else { return [:] }
        var result: [pid_t: UInt64] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = pid_t(parts[0]), let kb = UInt64(parts[1]) else { continue }
            result[pid] = kb * 1024
        }
        return result
    }

    private static func runTop() -> [pid_t: UInt64] {
        guard let output = run("/usr/bin/top", ["-l", "1", "-stats", "pid,mem"]) else { return [:] }
        var result: [pid_t: UInt64] = [:]
        var inTable = false
        for line in output.split(separator: "\n") {
            if line.hasPrefix("PID") { inTable = true; continue }
            guard inTable else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = pid_t(parts[0]), let bytes = parseTopSize(parts[1]) else { continue }
            result[pid] = bytes
        }
        return result
    }

    /// "4137M-", "7552K", "0B", "1.2G+" → bytes.
    static func parseTopSize(_ token: Substring) -> UInt64? {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "+-*"))
        guard let unit = trimmed.last, let value = Double(trimmed.dropLast()) else { return nil }
        let scale: Double
        switch unit {
        case "B": scale = 1
        case "K": scale = 1024
        case "M": scale = 1024 * 1024
        case "G": scale = 1024 * 1024 * 1024
        case "T": scale = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return UInt64(value * scale)
    }

    static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
