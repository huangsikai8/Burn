import Foundation
import SQLite3

struct BatteryShare: Identifiable {
    var id: String { key }
    let key: String
    let name: String
    let percent: Double

    static let otherKey = "__other"
}

struct HistoryPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let cpu: Double
    let memory: Double
    let energy: Double
    let watts: Double
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case hour = "1 h", day = "24 h", week = "7 d"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .hour: 3600
        case .day: 86_400
        case .week: 604_800
        }
    }
}

/// Per-app history on disk: one row per app per minute for 48 hours, rolled up to
/// 15-minute rows for 30 days, plus a battery ledger that charges each minute on
/// battery to the apps whose CPU energy drew it.
final class HistoryStore {
    private let queue = DispatchQueue(label: "com.sikaihuang.Burn.history", qos: .utility)
    private var db: OpaquePointer?
    private var bucket: MinuteBucket?
    private var lastMaintenance = Date.distantPast
    let fileURL: URL

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("history.sqlite")
        queue.sync {
            guard sqlite3_open(fileURL.path, &db) == SQLITE_OK else {
                db = nil
                return
            }
            exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
            exec("""
                CREATE TABLE IF NOT EXISTS app_minute(
                    ts INTEGER NOT NULL, key TEXT NOT NULL, name TEXT,
                    cpu REAL, memory REAL, energy REAL, watts REAL,
                    disk_read REAL, disk_write REAL, gpu REAL, wakeups REAL,
                    PRIMARY KEY(key, ts));
                CREATE TABLE IF NOT EXISTS app_quarter(
                    ts INTEGER NOT NULL, key TEXT NOT NULL, name TEXT,
                    cpu REAL, memory REAL, energy REAL, watts REAL,
                    disk_read REAL, disk_write REAL, gpu REAL, wakeups REAL,
                    PRIMARY KEY(key, ts));
                CREATE TABLE IF NOT EXISTS system_minute(
                    ts INTEGER PRIMARY KEY, cpu REAL, memory_used REAL, swap_used REAL,
                    pressure REAL, watts REAL, battery REAL, on_battery INTEGER);
                CREATE TABLE IF NOT EXISTS battery_minute(
                    ts INTEGER NOT NULL, key TEXT NOT NULL, name TEXT, percent REAL,
                    PRIMARY KEY(key, ts));
                CREATE INDEX IF NOT EXISTS app_minute_ts ON app_minute(ts);
                CREATE INDEX IF NOT EXISTS battery_minute_ts ON battery_minute(ts);
                """)
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    var sizeOnDisk: UInt64 {
        ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let path = fileURL.path + suffix
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
            return total + size
        }
    }

    // MARK: Recording

    /// Called on the main thread with every snapshot; the copying is cheap and the
    /// accumulation and writing happen on the history queue.
    func record(_ snapshot: Snapshot) {
        let weight = min(snapshot.interval, 60)
        guard weight > 0 else { return }

        var apps: [String: AppSample] = [:]
        for group in snapshot.groups {
            var sample = apps[group.historyKey] ?? AppSample(name: group.name)
            sample.cpu += group.cpuPercent
            sample.memory += Double(group.memory)
            sample.energy += group.energyImpact
            sample.watts += group.watts
            sample.diskRead += group.diskReadRate
            sample.diskWrite += group.diskWriteRate
            sample.gpu += group.gpuPercent
            sample.wakeups += group.idleWakeups
            apps[group.historyKey] = sample
        }
        let s = snapshot.system
        let system = SystemSample(
            cpu: s.cpuUser + s.cpuSystem, memoryUsed: Double(s.usedMemory), swapUsed: Double(s.swapUsed),
            pressure: s.pressurePercent, watts: s.systemWatts, battery: s.battery.map { Double($0.percent) },
            onBattery: s.battery.map { !$0.onExternalPower } ?? false, capacityWh: s.battery?.capacityWh)
        let date = snapshot.date

        queue.async { [weak self] in
            self?.accumulate(date: date, weight: weight, apps: apps, system: system)
        }
    }

    func flush() {
        queue.sync {
            if let bucket { write(bucket) }
            bucket = nil
        }
    }

    func clear() {
        queue.async { [weak self] in
            self?.bucket = nil
            self?.exec("DELETE FROM app_minute; DELETE FROM app_quarter; DELETE FROM system_minute; DELETE FROM battery_minute; VACUUM;")
        }
    }

    private func accumulate(date: Date, weight: Double, apps: [String: AppSample], system: SystemSample) {
        let minute = Int64(date.timeIntervalSince1970) / 60
        if let current = bucket, current.minute != minute {
            write(current)
            bucket = nil
        }
        var b = bucket ?? MinuteBucket(minute: minute)
        b.seconds += weight
        for (key, sample) in apps {
            var total = b.apps[key] ?? AppTotals(name: sample.name)
            total.seconds += weight
            total.cpu += sample.cpu * weight
            total.memory += sample.memory * weight
            total.energy += sample.energy * weight
            total.watts += sample.watts * weight
            total.diskRead += sample.diskRead * weight
            total.diskWrite += sample.diskWrite * weight
            total.gpu += sample.gpu * weight
            total.wakeups += sample.wakeups * weight
            if system.onBattery { total.batteryWattSeconds += sample.watts * weight }
            b.apps[key] = total
        }
        b.cpu += system.cpu * weight
        b.memoryUsed += system.memoryUsed * weight
        b.swapUsed += system.swapUsed * weight
        b.pressure += system.pressure * weight
        if let watts = system.watts {
            b.watts += watts * weight
            b.wattSeconds += weight
            if system.onBattery { b.batteryWattSeconds += watts * weight }
        }
        if system.onBattery { b.batterySeconds += weight }
        b.battery = system.battery ?? b.battery
        b.capacityWh = system.capacityWh ?? b.capacityWh
        bucket = b

        if Date().timeIntervalSince(lastMaintenance) > 3600 {
            lastMaintenance = Date()
            maintain()
        }
    }

    private func write(_ b: MinuteBucket) {
        guard db != nil, b.seconds > 0 else { return }
        let ts = b.minute * 60
        exec("BEGIN")
        defer { exec("COMMIT") }

        // Keep the rows that matter: anything with measurable cost, heaviest first.
        func averageMemory(_ t: AppTotals) -> Double { t.seconds > 0 ? t.memory / t.seconds : 0 }
        func worthKeeping(_ t: AppTotals) -> Bool {
            let cpu = t.cpu / b.seconds
            let watts = t.watts / b.seconds
            return cpu >= 0.05 || averageMemory(t) >= 30_000_000 || watts >= 0.01
        }
        let kept: [(String, AppTotals)] = b.apps.filter { worthKeeping($0.value) }.map { ($0.key, $0.value) }
        let rows = kept.sorted { averageMemory($0.1) > averageMemory($1.1) }.prefix(150)

        if let insert = prepare("INSERT OR REPLACE INTO app_minute VALUES(?,?,?,?,?,?,?,?,?,?,?)") {
            defer { sqlite3_finalize(insert) }
            for (key, t) in rows {
                sqlite3_reset(insert)
                sqlite3_bind_int64(insert, 1, ts)
                bind(insert, 2, key)
                bind(insert, 3, t.name)
                // Rates average over the whole minute; memory over the time the app existed.
                sqlite3_bind_double(insert, 4, t.cpu / b.seconds)
                sqlite3_bind_double(insert, 5, t.memory / t.seconds)
                sqlite3_bind_double(insert, 6, t.energy / b.seconds)
                sqlite3_bind_double(insert, 7, t.watts / b.seconds)
                sqlite3_bind_double(insert, 8, t.diskRead / b.seconds)
                sqlite3_bind_double(insert, 9, t.diskWrite / b.seconds)
                sqlite3_bind_double(insert, 10, t.gpu / b.seconds)
                sqlite3_bind_double(insert, 11, t.wakeups / b.seconds)
                sqlite3_step(insert)
            }
        }

        if let insert = prepare("INSERT OR REPLACE INTO system_minute VALUES(?,?,?,?,?,?,?,?)") {
            defer { sqlite3_finalize(insert) }
            sqlite3_bind_int64(insert, 1, ts)
            sqlite3_bind_double(insert, 2, b.cpu / b.seconds)
            sqlite3_bind_double(insert, 3, b.memoryUsed / b.seconds)
            sqlite3_bind_double(insert, 4, b.swapUsed / b.seconds)
            sqlite3_bind_double(insert, 5, b.pressure / b.seconds)
            if b.wattSeconds > 0 { sqlite3_bind_double(insert, 6, b.watts / b.wattSeconds) } else { sqlite3_bind_null(insert, 6) }
            if let battery = b.battery { sqlite3_bind_double(insert, 7, battery) } else { sqlite3_bind_null(insert, 7) }
            sqlite3_bind_int(insert, 8, b.batterySeconds > b.seconds / 2 ? 1 : 0)
            sqlite3_step(insert)
        }

        writeBattery(b, ts: ts)
    }

    /// Converts the minute's measured battery drain into percent of a full charge and
    /// charges it to apps by their CPU energy. Whatever no app accounts for — display,
    /// radios, GPU work, the SSD — goes to a single "other" row, so the parts always
    /// add up to what the battery actually lost.
    private func writeBattery(_ b: MinuteBucket, ts: Int64) {
        guard b.batteryWattSeconds > 0, let capacity = b.capacityWh, capacity > 0 else { return }
        let total = b.batteryWattSeconds / 3600 / capacity * 100
        var shares = b.apps.compactMap { key, t -> (String, String, Double)? in
            guard t.batteryWattSeconds > 0 else { return nil }
            return (key, t.name, t.batteryWattSeconds / 3600 / capacity * 100)
        }
        let attributed = shares.reduce(0) { $0 + $1.2 }
        if attributed > total, attributed > 0 {
            shares = shares.map { ($0.0, $0.1, $0.2 * total / attributed) }
        }
        let other = max(0, total - min(attributed, total))
        if other > 0 { shares.append((BatteryShare.otherKey, "Display, radios & other", other)) }

        guard let insert = prepare("INSERT OR REPLACE INTO battery_minute VALUES(?,?,?,?)") else { return }
        defer { sqlite3_finalize(insert) }
        for (key, name, percent) in shares where percent > 0.0005 {
            sqlite3_reset(insert)
            sqlite3_bind_int64(insert, 1, ts)
            bind(insert, 2, key)
            bind(insert, 3, name)
            sqlite3_bind_double(insert, 4, percent)
            sqlite3_step(insert)
        }
    }

    private func maintain() {
        let now = Int64(Date().timeIntervalSince1970)
        let minuteCutoff = now - 48 * 3600
        let longCutoff = now - 30 * 86_400
        exec("""
            INSERT OR REPLACE INTO app_quarter
                SELECT (ts / 900) * 900, key, MAX(name), AVG(cpu), AVG(memory), AVG(energy), AVG(watts),
                       AVG(disk_read), AVG(disk_write), AVG(gpu), AVG(wakeups)
                FROM app_minute WHERE ts < \(minuteCutoff) GROUP BY ts / 900, key;
            DELETE FROM app_minute WHERE ts < \(minuteCutoff);
            DELETE FROM app_quarter WHERE ts < \(longCutoff);
            DELETE FROM system_minute WHERE ts < \(longCutoff);
            DELETE FROM battery_minute WHERE ts < \(longCutoff);
            """)
    }

    // MARK: Queries

    func series(key: String, range: HistoryRange, completion: @escaping @MainActor ([HistoryPoint]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let since = Int64(Date().timeIntervalSince1970 - range.seconds)
            let step: Int64 = range == .week ? 900 : (range == .day ? 300 : 60)
            let sql = """
                SELECT (ts / \(step)) * \(step) AS t, AVG(cpu), AVG(memory), AVG(energy), AVG(watts) FROM (
                    SELECT ts, cpu, memory, energy, watts FROM app_minute WHERE key = ?1 AND ts >= ?2
                    UNION ALL
                    SELECT ts, cpu, memory, energy, watts FROM app_quarter WHERE key = ?1 AND ts >= ?2
                ) GROUP BY t ORDER BY t
                """
            var points: [HistoryPoint] = []
            if let statement = self.prepare(sql) {
                self.bind(statement, 1, key)
                sqlite3_bind_int64(statement, 2, since)
                while sqlite3_step(statement) == SQLITE_ROW {
                    points.append(HistoryPoint(
                        date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                        cpu: sqlite3_column_double(statement, 1), memory: sqlite3_column_double(statement, 2),
                        energy: sqlite3_column_double(statement, 3), watts: sqlite3_column_double(statement, 4)))
                }
                sqlite3_finalize(statement)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(points) } }
        }
    }

    func batteryToday(completion: @escaping @MainActor ([BatteryShare]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            // Include the minute still accumulating, or the ledger lags a minute behind.
            if let bucket = self.bucket, bucket.batteryWattSeconds > 0 {
                self.write(bucket)
            }
            let since = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
            var shares: [BatteryShare] = []
            if let statement = self.prepare("""
                SELECT key, MAX(name), SUM(percent) FROM battery_minute WHERE ts >= ?1
                GROUP BY key ORDER BY 3 DESC LIMIT 12
                """) {
                sqlite3_bind_int64(statement, 1, since)
                while sqlite3_step(statement) == SQLITE_ROW {
                    shares.append(BatteryShare(key: self.string(statement, 0), name: self.string(statement, 1),
                                               percent: sqlite3_column_double(statement, 2)))
                }
                sqlite3_finalize(statement)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(shares) } }
        }
    }

    /// Apps whose memory has climbed steadily for at least 90 minutes. A straight-line
    /// fit with a high R² separates a leak from the normal saw-tooth of caches filling
    /// and being purged.
    func findLeaks(minimumBytesPerHour: Double, completion: @escaping @MainActor ([LeakFinding]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let since = Int64(Date().timeIntervalSince1970) - 3 * 3600
            var series: [String: (name: String, xs: [Double], ys: [Double])] = [:]
            if let statement = self.prepare("SELECT key, name, ts, memory FROM app_minute WHERE ts >= ?1 ORDER BY key, ts") {
                sqlite3_bind_int64(statement, 1, since)
                while sqlite3_step(statement) == SQLITE_ROW {
                    let key = self.string(statement, 0)
                    var entry = series[key] ?? (self.string(statement, 1), [], [])
                    entry.xs.append(Double(sqlite3_column_int64(statement, 2) - since) / 3600)
                    entry.ys.append(sqlite3_column_double(statement, 3))
                    series[key] = entry
                }
                sqlite3_finalize(statement)
            }

            var leaks: [LeakFinding] = []
            for (key, entry) in series where entry.xs.count >= 60 {
                guard let first = entry.xs.first, let last = entry.xs.last, last - first >= 1.5,
                      let fit = LinearFit(xs: entry.xs, ys: entry.ys),
                      fit.slope >= minimumBytesPerHour, fit.r2 >= 0.8 else { continue }
                let from = fit.intercept + fit.slope * first
                let to = fit.intercept + fit.slope * last
                guard to >= 300_000_000, to - from >= 400_000_000 else { continue }
                leaks.append(LeakFinding(key: key, name: entry.name, bytesPerHour: fit.slope, hours: last - first,
                                         fromBytes: from, toBytes: to))
            }
            leaks.sort { $0.bytesPerHour > $1.bytesPerHour }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(leaks) } }
        }
    }

    // MARK: SQLite helpers

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK ? statement : nil
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}

private struct AppSample {
    var name: String
    var cpu = 0.0, memory = 0.0, energy = 0.0, watts = 0.0
    var diskRead = 0.0, diskWrite = 0.0, gpu = 0.0, wakeups = 0.0
}

private struct SystemSample {
    let cpu: Double
    let memoryUsed: Double
    let swapUsed: Double
    let pressure: Double
    let watts: Double?
    let battery: Double?
    let onBattery: Bool
    let capacityWh: Double?
}

private struct AppTotals {
    var name: String
    var seconds = 0.0
    var cpu = 0.0, memory = 0.0, energy = 0.0, watts = 0.0
    var diskRead = 0.0, diskWrite = 0.0, gpu = 0.0, wakeups = 0.0
    var batteryWattSeconds = 0.0
}

private struct MinuteBucket {
    let minute: Int64
    var seconds = 0.0
    var apps: [String: AppTotals] = [:]
    var cpu = 0.0, memoryUsed = 0.0, swapUsed = 0.0, pressure = 0.0
    var watts = 0.0
    var wattSeconds = 0.0
    var batteryWattSeconds = 0.0
    var batterySeconds = 0.0
    var battery: Double?
    var capacityWh: Double?
}
