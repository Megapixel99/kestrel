import Foundation

/// Reads real memory for the WebKit content processes backing our tabs.
///
/// WKWebView gives no public API for its WebContent process id, so we enumerate the
/// processes directly. `phys_footprint` is what macOS's own memory-pressure system acts
/// on -- it excludes clean shared file-backed pages -- so it is the honest number here,
/// and it is the same measure B3 used.
enum MemoryProbe {

    struct ProcSample {
        let pid: Int32
        let footprintBytes: Int64
        let rssBytes: Int64
    }

    /// All WebKit WebContent processes currently alive, whoever spawned them.
    /// Filtering to our own children is done by `Snapshot` below.
    static func webContentProcesses() -> [ProcSample] {
        // ps gives rss cheaply for every process in one call; footprint needs a second
        // pass but only for the handful we care about.
        guard let out = run("/bin/ps", ["-axo", "pid=,rss=,comm="]) else { return [] }
        var samples: [ProcSample] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[0]), let rssKB = Int64(parts[1])
            else { continue }
            let comm = parts[2...].joined(separator: " ")
            guard comm.contains("com.apple.WebKit.WebContent") else { continue }
            samples.append(ProcSample(pid: pid,
                                      footprintBytes: footprint(pid: pid) ?? rssKB * 1024,
                                      rssBytes: rssKB * 1024))
        }
        return samples
    }

    /// phys_footprint in bytes for one pid, via /usr/bin/footprint.
    static func footprint(pid: Int32) -> Int64? {
        guard let out = run("/usr/bin/footprint", ["--", String(pid)]) else { return nil }
        // "Process [1234]: 64-bit    Footprint: 123456 KB (4096 bytes per page)"
        guard let r = out.range(of: #"Footprint:\s+([\d.]+)\s*(KB|MB|GB)"#,
                                options: .regularExpression) else { return nil }
        let field = String(out[r])
        let scanner = Scanner(string: field)
        _ = scanner.scanUpToCharacters(from: .decimalDigits)
        guard let value = scanner.scanDouble() else { return nil }
        let unit = field.contains("GB") ? 1024.0 * 1024 * 1024
                 : field.contains("MB") ? 1024.0 * 1024 : 1024.0
        return Int64(value * unit)
    }

    /// Total footprint across all WebContent processes, plus the count.
    struct Snapshot {
        let totalFootprint: Int64
        let processCount: Int
        let perProcess: [ProcSample]

        var totalMB: Double { Double(totalFootprint) / 1_048_576 }
    }

    static func snapshot() -> Snapshot {
        let procs = webContentProcesses()
        return Snapshot(totalFootprint: procs.reduce(0) { $0 + $1.footprintBytes },
                        processCount: procs.count,
                        perProcess: procs)
    }

    /// This process's own footprint (the UI process), for completeness.
    static func selfFootprint() -> Int64 {
        footprint(pid: ProcessInfo.processInfo.processIdentifier) ?? 0
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

extension MemoryProbe {
    /// Essentially free liveness check -- no process spawn. Used for polling loops
    /// where shelling out to `footprint` per tick would dominate the measurement.
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func aliveCount(_ pids: Set<Int32>) -> Int {
        pids.filter { isAlive($0) }.count
    }

    /// Footprint for a specific set of pids only -- one `footprint` call each,
    /// instead of one per WebContent process on the machine.
    static func footprintOf(_ pids: Set<Int32>) -> Int64 {
        pids.reduce(Int64(0)) { $0 + (isAlive($1) ? (footprint(pid: $1) ?? 0) : 0) }
    }
}

extension MemoryProbe {
    /// Just the pids, without paying for a footprint call on each -- used for the
    /// pid-set diffing that maps a tab to its WebContent process.
    static func webContentPids() -> [Int32] {
        guard let out = run("/bin/ps", ["-axo", "pid=,comm="]) else { return [] }
        var pids: [Int32] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int32(parts[0]) else { continue }
            if parts[1...].joined(separator: " ").contains("com.apple.WebKit.WebContent") {
                pids.append(pid)
            }
        }
        return pids
    }
}
