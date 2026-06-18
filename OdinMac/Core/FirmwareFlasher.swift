import Foundation
import Combine

enum FlashState {
    case idle
    case connecting
    case handshaking
    case gettingDeviceInfo
    case downloadingPIT
    case flashing(partition: String, progress: Double)
    case finishing
    case success
    case failed(Error)
    case cancelled
}

enum FlashError: LocalizedError {
    case noEngine
    case noDevice
    case nothingToFlash
    case extractionFailed(String)
    case compressedNeedsLZ4([String])

    var errorDescription: String? {
        switch self {
        case .noEngine:
            return "Heimdall engine missing. Rebuild OdinMac with build.sh."
        case .noDevice:
            return "No Samsung device detected in Download Mode."
        case .nothingToFlash:
            return "None of the selected files matched a partition in the device PIT. Nothing was flashed."
        case .extractionFailed(let f):
            return "Failed to extract \(f)."
        case .compressedNeedsLZ4(let files):
            return "These images are LZ4-compressed and need the 'lz4' tool (brew install lz4):\n" +
                   files.joined(separator: ", ")
        }
    }
}

@MainActor
final class FirmwareFlasher: ObservableObject {
    @Published private(set) var state: FlashState = .idle
    @Published private(set) var overallProgress: Double = 0
    @Published private(set) var currentPartition: String = ""
    @Published private(set) var pitTable: PITTable?

    var onLog: ((String, LogLevel) -> Void)?

    private let heimdall: HeimdallManager
    private var task: Task<Void, Never>?

    // progress tracking across the single heimdall flash invocation
    private var totalParts = 0
    private var completedParts = 0

    init(heimdall: HeimdallManager) {
        self.heimdall = heimdall
    }

    // MARK: - Flash

    func startFlash(config: FlashConfiguration) {
        guard config.hasAnyFile else { return }
        state = .connecting
        overallProgress = 0
        completedParts = 0
        totalParts = 0

        task = Task {
            do {
                try await performFlash(config: config)
            } catch is CancellationError {
                state = .cancelled
                log("Flash cancelled.", .warning)
            } catch {
                state = .failed(error)
                log("Flash failed: \(error.localizedDescription)", .error)
            }
        }
    }

    func cancel() {
        heimdall.cancel()
        task?.cancel()
        state = .cancelled
        log("Cancellation requested. Stopping Heimdall…", .warning)
    }

    // MARK: - Pipeline

    private func performFlash(config: FlashConfiguration) async throws {
        guard heimdall.isAvailable else { throw FlashError.noEngine }

        // 1. Confirm a device is actually in download mode.
        state = .connecting
        log("Checking for device in Download Mode…")
        let present = await detect()
        guard present else { throw FlashError.noDevice }
        log("Device detected in Download Mode.", .success)
        try Task.checkCancellation()

        // 2. Extract selected Odin archives. Stock CSC packages normally contain
        // a PIT, which avoids known device-PIT transfer failures in Heimdall.
        state = .gettingDeviceInfo
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("odinmac-flash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var extractedFiles: [URL] = []
        for slot in config.slots where slot.fileURL != nil {
            let archive = slot.fileURL!
            log("Extracting \(slot.label): \(archive.lastPathComponent)")
            extractedFiles += try extractArchive(archive, into: workDir, tag: slot.id)
        }

        // 3. Decide how to map partitions, always within a SINGLE Odin session.
        //    - Firmware PIT present → OdinMac maps each image locally and flashes
        //      with --use-local-pit (no device-PIT download needed).
        //    - No firmware PIT → flash in one session and let Heimdall download the
        //      device PIT itself, mapping each file by its PIT flash filename.
        //      This avoids a separate download-pit session; many devices refuse the
        //      second Odin session that a standalone PIT download would require.
        let bundledPIT = Self.firmwarePIT(in: extractedFiles)

        let lz4 = locateLZ4()
        log("lz4 tool: \(lz4?.path ?? "not found")", .info)

        // Inform the user when a Magisk-patched archive only patches BOOT.
        let hasMagiskPatch = config.slots.contains {
            $0.fileURL?.lastPathComponent.lowercased().hasPrefix("magisk_patched") == true
        }
        if hasMagiskPatch {
            log("Note: magisk_patched archives only contain a patched BOOT image. SYSTEM and other partitions are NOT included and will not be changed. Flash the full stock AP first if a system upgrade is also needed.", .info)
        }

        state = .gettingDeviceInfo
        let partitions: [FlashPartition]
        let flashPIT: URL?
        var needLZ4: [String] = []

        if let bundledPIT {
            // Firmware-PIT path: map each image against the firmware PIT.
            let pit = try PITParser.parse(try Data(contentsOf: bundledPIT))
            pitTable = pit
            log("Using firmware PIT for partition mapping: \(bundledPIT.lastPathComponent)", .success)
            log("PIT: \(pit.entryCount) partitions.", .success)
            try Task.checkCancellation()

            var flashPlan = FlashPartitionPlan()
            var skipped: [String] = []
            for image in extractedFiles where image.pathExtension.lowercased() != "pit" {
                guard let (name, prepared) = try mapImage(image, pit: pit, lz4: lz4, needLZ4: &needLZ4) else {
                    skipped.append(image.lastPathComponent)
                    continue
                }
                let partition = FlashPartition(name: name, file: prepared)
                if let replaced = flashPlan.add(partition) {
                    log("  \(image.lastPathComponent)  →  \(name)  [replaces \(replaced.file.lastPathComponent)]", .warning)
                } else {
                    log("  \(image.lastPathComponent)  →  \(name)", .success)
                }
            }
            if !skipped.isEmpty {
                log("Skipped (no PIT match): \(skipped.joined(separator: ", "))", .warning)
            }
            partitions = flashPlan.partitions
            flashPIT = bundledPIT
        } else {
            // No firmware PIT: single-session flash. Decompress LZ4 images, then pass
            // each file to Heimdall as "--<filename> <path>". Heimdall downloads the
            // device PIT in the same session and maps every file by its PIT flash
            // filename, skipping anything the PIT does not define.
            log("No firmware PIT. Heimdall will map files using the device PIT in one session.")
            var files: [FlashPartition] = []
            for image in extractedFiles where image.pathExtension.lowercased() != "pit" {
                guard let prepared = try prepareRawImage(image, lz4: lz4, needLZ4: &needLZ4) else { continue }
                files.append(FlashPartition(name: prepared.lastPathComponent, file: prepared))
                log("  queued \(prepared.lastPathComponent)", .info)
            }
            partitions = files
            flashPIT = nil
        }

        // Safety: never flash a compressed blob as a raw image.
        if !needLZ4.isEmpty { throw FlashError.compressedNeedsLZ4(needLZ4) }
        guard !partitions.isEmpty else { throw FlashError.nothingToFlash }
        log("Flash plan: \(partitions.map { $0.name }.joined(separator: ", "))", .info)
        try Task.checkCancellation()

        // 4. Flash everything in a single Heimdall invocation / Odin session.
        totalParts = partitions.count
        completedParts = 0
        currentPartition = partitions.first?.name ?? ""
        state = .flashing(partition: currentPartition, progress: 0)
        log("Flashing \(partitions.count) partition(s) via Heimdall…")

        let repartition = flashPIT != nil && config.repartition
        if repartition { log("Re-partition enabled: the selected PIT will be written.", .warning) }

        try await heimdall.flash(
            partitions: partitions,
            pit: flashPIT,
            repartition: repartition,
            resume: false,
            reboot: config.rebootAfterFlash
        ) { [weak self] line in
            Task { @MainActor in self?.handleFlashLine(line) }
        }

        // 5. Done.
        state = .finishing
        overallProgress = 1.0
        state = .success
        log(config.rebootAfterFlash ? "Flash complete. Device rebooting." : "Flash complete.", .success)
    }

    // MARK: - Heimdall output → progress

    private func handleFlashLine(_ line: String) {
        if let range = line.range(of: "Uploading ") {
            currentPartition = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            state = .flashing(partition: currentPartition, progress: 0)
            log("Uploading \(currentPartition)…", .info)
        } else if line.localizedCaseInsensitiveContains("upload successful") {
            completedParts = min(completedParts + 1, totalParts)
            overallProgress = totalParts > 0 ? Double(completedParts) / Double(totalParts) : 0
            log("\(currentPartition) upload successful.", .success)
        } else if !line.isEmpty && line.allSatisfy({ $0.isNumber || $0 == "%" }) {
            // Heimdall percentage output ("0%", "100%", "0%1%…100%"): update state only, never log.
            if let pct = parsePercent(line) {
                let within = (pct / 100.0) / Double(max(totalParts, 1))
                overallProgress = min(1.0, fileBaseProgress() + within)
                state = .flashing(partition: currentPartition, progress: pct / 100.0)
            }
        } else {
            // Errors, warnings, session events: always log.
            let lvl = classify(line)
            if lvl != .info || !line.isEmpty {
                log(line, lvl)
            }
        }
    }

    /// Colour-codes raw Heimdall output the way Odin's log does.
    private func classify(_ line: String) -> LogLevel {
        let l = line.lowercased()
        if l.contains("error") || l.contains("failed") || l.contains("invalid") ||
           l.contains("duplicate argument") || l.contains("unknown argument") { return .error }
        if l.contains("warning") || l.contains("retry") { return .warning }
        if l.contains("success") || l.contains("complete") || l.hasPrefix("done") { return .success }
        return .info
    }

    private func fileBaseProgress() -> Double {
        totalParts > 0 ? Double(completedParts) / Double(totalParts) : 0
    }

    private func parsePercent(_ line: String) -> Double? {
        guard let pIdx = line.firstIndex(of: "%") else { return nil }
        var digits = ""
        var i = pIdx
        while i > line.startIndex {
            i = line.index(before: i)
            let c = line[i]
            if c.isNumber { digits.insert(c, at: digits.startIndex) } else { break }
        }
        return digits.isEmpty ? nil : Double(digits)
    }

    // MARK: - Archive handling

    /// Extracts a .tar / .tar.md5 archive into `dir/<tag>` and returns the
    /// regular files it produced. (tar stops at the archive EOF marker, so the
    /// trailing MD5 checksum on .tar.md5 files is harmless.)
    private func extractArchive(_ archive: URL, into dir: URL, tag: String) throws -> [URL] {
        let dest = dir.appendingPathComponent(tag)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-xf", archive.path, "-C", dest.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        // Exit code 1 = warnings only (e.g. trailing MD5 checksum on .tar.md5 files).
        // Exit code 2+ indicates a fatal error.
        guard proc.terminationStatus <= 1 else {
            throw FlashError.extractionFailed(archive.lastPathComponent)
        }

        // Enumerate recursively so files inside subdirectories are found too.
        var result: [URL] = []
        if let e = FileManager.default.enumerator(
            at: dest,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in e {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    result.append(url)
                }
            }
        }
        return result
    }

    /// Maps an extracted image file to (partitionName, fileToFlash) using the
    /// PIT's flash-filename field. Decompresses .lz4 first; if lz4 is missing it
    /// records the file in `needLZ4` so the flash can abort safely.
    private func mapImage(_ image: URL, pit: PITTable, lz4: URL?, needLZ4: inout [String]) throws -> (String, URL)? {
        var matchName = image.lastPathComponent
        var fileToFlash = image

        if matchName.lowercased().hasSuffix(".lz4") {
            guard let lz4 else { needLZ4.append(matchName); return nil }
            let out = image.deletingPathExtension()   // drop .lz4
            let proc = Process()
            proc.executableURL = lz4
            proc.arguments = ["-d", "-f", image.path, out.path]
            proc.standardError = Pipe()
            proc.standardOutput = Pipe()
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { throw FlashError.extractionFailed(matchName) }
            matchName = out.lastPathComponent
            fileToFlash = out
        }

        guard let name = partitionName(forFile: matchName, in: pit) else { return nil }
        return (name, fileToFlash)
    }

    /// Decompresses an `.lz4` image (if needed) and returns the raw file ready to
    /// flash. Used by the single-session, no-firmware-PIT path where Heimdall maps
    /// each file to a partition itself. Records the file in `needLZ4` (and returns
    /// nil) when an `.lz4` image is found but the lz4 tool is missing, so the flash
    /// can abort safely instead of sending a compressed blob to the device.
    private func prepareRawImage(_ image: URL, lz4: URL?, needLZ4: inout [String]) throws -> URL? {
        let name = image.lastPathComponent
        guard name.lowercased().hasSuffix(".lz4") else { return image }

        guard let lz4 else { needLZ4.append(name); return nil }
        let out = image.deletingPathExtension()   // drop .lz4
        let proc = Process()
        proc.executableURL = lz4
        proc.arguments = ["-d", "-f", image.path, out.path]
        proc.standardError = Pipe()
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw FlashError.extractionFailed(name) }
        return out
    }

    private func partitionName(forFile fileName: String, in pit: PITTable) -> String? {
        let target = normalize(fileName)
        // 1. Exact match against PIT flashFileName (normalised).
        for e in pit.entries where !e.flashFileName.isEmpty {
            if normalize(e.flashFileName) == target { return e.partitionName }
        }
        // 2. Keyword fallback for files whose names don't exactly match the PIT
        //    (e.g. a magisk_patched boot may omit the .img suffix or use a prefix).
        //    More-specific keywords are checked first so vendor_boot beats vendor/boot.
        let keywords: [(kw: String, part: String)] = [
            ("init_boot",   "INIT_BOOT"),
            ("vendor_boot", "VENDOR_BOOT"),
            ("vbmeta_system","VBMETA_SYSTEM"),
            ("recovery",    "RECOVERY"),
            ("userdata",    "USERDATA"),
            ("vbmeta",      "VBMETA"),
            ("super",       "SUPER"),
            ("system",      "SYSTEM"),
            ("vendor",      "VENDOR"),
            ("dtbo",        "DTBO"),
            ("cache",       "CACHE"),
            ("boot",        "BOOT"),
        ]
        for (kw, part) in keywords where target.contains(kw) {
            if let e = pit.entries.first(where: { $0.partitionName.uppercased() == part }) {
                return e.partitionName
            }
        }
        return nil
    }

    /// Lower-cases and strips trailing .lz4 / .ext4 so "super.img.lz4",
    /// "super.img.ext4" and "super.img" all compare equal.
    private func normalize(_ s: String) -> String {
        var n = s.lowercased()
        for ext in [".lz4", ".ext4"] where n.hasSuffix(ext) {
            n = String(n.dropLast(ext.count))
        }
        return n
    }

    private func locateLZ4() -> URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("lz4"),
           fm.isExecutableFile(atPath: res.path) { return res }
        for p in ["/opt/homebrew/bin/lz4", "/usr/local/bin/lz4"] where fm.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    static func firmwarePIT(in files: [URL]) -> URL? {
        files.first(where: { $0.pathExtension.lowercased() == "pit" })
    }

    // MARK: - Detect helper

    private func detect() async -> Bool {
        let h = heimdall   // capture locally so the background closure doesn't touch the actor
        return await withCheckedContinuation { cont in
            h.queue.async {
                cont.resume(returning: h.detectOnQueue())
            }
        }
    }

    private func log(_ msg: String, _ level: LogLevel = .info) {
        onLog?(msg, level)
    }
}
