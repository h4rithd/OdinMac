import Foundation

/// Drives the bundled Heimdall CLI (the proven, libusb-based Samsung flashing
/// engine) as a subprocess. All device I/O goes through Heimdall, so OdinMac
/// never speaks the raw Odin protocol itself. That is what keeps flashing safe.
///
/// All mutable state (`current`, `isBusy`) is mutated only on `queue`, so the
/// type is safe to share across actors.
final class HeimdallManager: @unchecked Sendable {

    enum HeimdallError: LocalizedError {
        case notFound
        case commandFailed(String, String)   // command, captured output
        case reconnectRequired
        case firmwarePITRequired

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "Heimdall engine not found inside OdinMac.app. Rebuild with build.sh."
            case .commandFailed(let cmd, let out):
                let tail = out.split(separator: "\n").suffix(4).joined(separator: "\n")
                return "heimdall \(cmd) failed:\n\(tail)"
            case .reconnectRequired:
                return "The Samsung USB interface is stuck. Disconnect the cable, exit and re-enter Download Mode, reconnect the cable, then try again."
            case .firmwarePITRequired:
                return "This phone cannot reliably send its PIT through Heimdall. Select the matching CSC or HOME_CSC firmware archive containing a .pit file, then try again."
            }
        }
    }

    /// Serial queue: guarantees we never run two Heimdall processes against the
    /// same device at once (e.g. a detect poll during a flash).
    let queue = DispatchQueue(label: "com.odinmac.heimdall")

    private var current: Process?
    private(set) var isBusy = false

    // MARK: - Locating the engine

    /// Resolved path to the heimdall binary, or nil if it can't be found.
    let heimdallURL: URL? = {
        let fm = FileManager.default
        // 1) Bundled inside the .app (the normal, self-contained case)
        if let res = Bundle.main.resourceURL?.appendingPathComponent("heimdall"),
           fm.isExecutableFile(atPath: res.path) {
            return res
        }
        // 2) Common locations / repo checkout (useful when run from build dir)
        let candidates = [
            "/opt/homebrew/bin/heimdall",
            "/usr/local/bin/heimdall",
            FileManager.default.currentDirectoryPath + "/vendor/heimdall/heimdall",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }()

    var isAvailable: Bool { heimdallURL != nil }

    var version: String {
        guard isAvailable else { return "not found" }
        return queue.sync { runSync(["version"]).output.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - Detection (used by the connection poller)

    /// Quick, non-destructive check (~10ms). Returns true if a download-mode
    /// device is present. MUST be dispatched on `queue` by the caller.
    func detectOnQueue() -> Bool {
        runSync(["detect"]).exitCode == 0
    }

    // MARK: - PIT

    /// Downloads and returns the device's PIT (partition table) without rebooting.
    func downloadPIT(onLine: @escaping (String) -> Void) async throws -> Data {
        try await withBusyQueue {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("odinmac-\(UUID().uuidString).pit")
            defer { try? FileManager.default.removeItem(at: tmp) }

            var result = self.runSync(Self.downloadPITArguments(output: tmp), onLine: onLine)
            if result.exitCode != 0, Self.needsResumeRetry(result.output) {
                onLine("Existing Download Mode session detected. Retrying PIT download with --resume.")
                Thread.sleep(forTimeInterval: 0.5)
                result = self.runSync(Self.downloadPITArguments(output: tmp, resume: true), onLine: onLine)
            }

            guard result.exitCode == 0 else {
                if Self.needsReconnect(result.output) { throw HeimdallError.reconnectRequired }
                if Self.needsFirmwarePIT(result.output) { throw HeimdallError.firmwarePITRequired }
                throw HeimdallError.commandFailed("download-pit", result.output)
            }

            let data = try Data(contentsOf: tmp)
            guard !data.isEmpty else {
                throw HeimdallError.commandFailed("download-pit", "Heimdall returned an empty PIT file.")
            }
            return data
        }
    }

    static func downloadPITArguments(output: URL, resume: Bool = false) -> [String] {
        var args = ["download-pit", "--output", output.path, "--no-reboot"]
        if resume { args.append("--resume") }
        return args
    }

    // MARK: - Flash

    /// Flashes a set of (partitionName, imageFile) pairs in a single Heimdall
    /// invocation, exactly how Odin applies a firmware set atomically.
    func flash(
        partitions: [FlashPartition],
        pit: URL?,
        repartition: Bool,
        resume: Bool,
        reboot: Bool,
        onLine: @escaping (String) -> Void
    ) async throws {
        try await withBusyQueue {
            let args = Self.flashArguments(
                partitions: partitions,
                pit: pit,
                repartition: repartition,
                resume: resume,
                reboot: reboot
            )
            let r = self.runSync(args, onLine: onLine)
            guard Self.isSuccessfulFlashResult(exitCode: r.exitCode, output: r.output) else {
                if Self.needsReconnect(r.output) { throw HeimdallError.reconnectRequired }
                throw HeimdallError.commandFailed("flash", r.output)
            }
        }
    }

    static func flashArguments(
        partitions: [FlashPartition],
        pit: URL?,
        repartition: Bool,
        resume: Bool,
        reboot: Bool
    ) -> [String] {
        var args = ["flash"]
        if let pit {
            if repartition {
                args.append("--repartition")
            } else {
                // OdinMac's bundled Heimdall patch maps against this PIT
                // without writing it to the phone or downloading the device PIT.
                args.append("--use-local-pit")
            }
            args += ["--pit", pit.path]
        }
        for partition in partitions {
            args += ["--\(partition.name)", partition.file.path]
        }
        if resume { args.append("--resume") }
        if !reboot { args.append("--no-reboot") }
        return args
    }

    /// Heimdall 1.4.2 returns exit code 0 for some argument-parser failures.
    /// Reject its usage/error output so OdinMac never reports a no-op as success.
    static func isSuccessfulFlashResult(exitCode: Int32, output: String) -> Bool {
        guard exitCode == 0 else { return false }
        let text = output.lowercased()
        let argumentErrors = [
            "duplicate argument:",
            "unknown argument:",
            "invalid argument:",
            "unknown argument type:",
        ]
        if argumentErrors.contains(where: text.contains) { return false }
        return !(text.contains("action: flash") && text.contains("arguments:"))
    }

    static func needsResumeRetry(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("protocol initialisation failed")
    }

    static func needsReconnect(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("setting up interface failed") ||
               text.contains("claiming interface failed") ||
               text.contains("failed to access device") ||
               text.contains("failed to begin session") ||
               text.contains("pipe is stalled") ||
               text.contains("bulk transfer failed")
    }

    static func needsFirmwarePIT(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("failed to receive PIT file part")
    }

    /// Terminates an in-progress Heimdall process (used by the Stop button).
    func cancel() {
        queue.async { self.current?.terminate() }
    }

    // MARK: - Process plumbing

    private func withBusyQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.isBusy = true
                defer { self.isBusy = false }
                do { cont.resume(returning: try work()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private struct RunResult { let exitCode: Int32; let output: String }

    /// Runs heimdall synchronously, streaming merged stdout+stderr line-by-line.
    /// Heimdall uses '\r' to redraw progress, so we treat both CR and LF as
    /// line breaks. Must be called on `queue`.
    private func runSync(_ args: [String], onLine: ((String) -> Void)? = nil) -> RunResult {
        guard let url = heimdallURL else { return RunResult(exitCode: -1, output: "heimdall not found") }

        let proc = Process()
        proc.executableURL = url
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do { try proc.run() }
        catch { return RunResult(exitCode: -1, output: "Failed to launch heimdall: \(error.localizedDescription)") }

        current = proc
        let handle = pipe.fileHandleForReading
        var pending = Data()
        var full = Data()

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }          // EOF
            pending.append(chunk)
            full.append(chunk)
            while let idx = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = pending[pending.startIndex..<idx]
                if let s = String(data: line, encoding: .utf8) {
                    let t = s.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { onLine?(t) }
                }
                pending.removeSubrange(pending.startIndex...idx)
            }
        }
        if let s = String(data: pending, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { onLine?(t) }
        }

        proc.waitUntilExit()
        current = nil
        let output = String(data: full, encoding: .utf8) ?? ""
        return RunResult(exitCode: proc.terminationStatus, output: output)
    }
}
