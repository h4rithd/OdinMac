import Foundation
import Combine
import IOKit

/// Watches for a Samsung device in Download Mode.
///
/// Detection uses two independent signals OR'd together, so a hiccup in either
/// one never hides a genuinely-connected device:
///
///  1. `heimdall detect` — confirms the device answers the Odin handshake.
///  2. IOKit registry scan — finds a Samsung device (VID 0x04E8) whose product
///     ID is a known Download Mode PID, read directly from the USB registry.
///     This needs no interface claim and no subprocess, so it works even when
///     the device's USB interface is busy or macOS hasn't surfaced it to the
///     `heimdall` subprocess yet.
///
/// IMPORTANT: IOKit is used as an *additional* signal, never as a gate in front
/// of Heimdall. (An earlier version gated `heimdall detect` behind a USB-vendor
/// match built with `IOServiceMatching` + an `idVendor` key in the matching
/// dictionary; that style of match silently returns nothing on macOS, which
/// suppressed all detection. The reliable approach — used below — is to
/// enumerate the device nodes and read each one's `idVendor`/`idProduct`.)
final class USBDeviceManager: ObservableObject {

    /// Samsung Electronics USB vendor ID.
    static let samsungVID = 0x04E8
    /// Samsung Download / Odin mode product IDs (per Heimdall's device list).
    static let downloadModePIDs: Set<Int> = [0x6601, 0x685D, 0x68C3]

    @Published private(set) var isConnected = false
    @Published private(set) var deviceInfo: DeviceInfo?
    /// True when *any* Samsung device is visible on the USB bus, even if it
    /// hasn't entered Download Mode. Lets the UI tell "bad cable / wrong mode"
    /// apart from "nothing plugged in".
    @Published private(set) var usbBusPresent = false

    private let heimdall: HeimdallManager
    private var timer: Timer?
    private var inFlight = false
    private var onConnected: ((Bool) -> Void)?

    init(heimdall: HeimdallManager) {
        self.heimdall = heimdall
    }

    func startMonitoring(onConnected: @escaping (Bool) -> Void) {
        self.onConnected = onConnected
        poll()
        let t = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard !inFlight, !heimdall.isBusy else { return }
        inFlight = true
        heimdall.queue.async { [weak self] in
            guard let self else { return }

            let bus = Self.samsungBusState()
            // OR the two signals — either one alone is enough to count as connected.
            let inDownloadMode = self.heimdall.detectOnQueue() || bus.downloadMode

            DispatchQueue.main.async {
                self.inFlight = false
                self.usbBusPresent = bus.present
                guard inDownloadMode != self.isConnected else { return }
                self.isConnected = inDownloadMode
                self.deviceInfo = inDownloadMode
                    ? DeviceInfo(productName: "Samsung (Download Mode)",
                                 platform: "Odin / Download Mode")
                    : nil
                self.onConnected?(inDownloadMode)
            }
        }
    }

    /// Scans the IOKit USB registry for Samsung devices by reading each device
    /// node's `idVendor` / `idProduct` properties directly. Never opens or claims
    /// an interface, so it is safe to call at any time, including mid-flash.
    ///
    /// - Returns: `present` — a Samsung device (VID 0x04E8) is on the bus;
    ///            `downloadMode` — its product ID is a known Download Mode PID.
    static func samsungBusState() -> (present: Bool, downloadMode: Bool) {
        var present = false
        var downloadMode = false

        // IOUSBHostDevice is the modern class (macOS 10.11+); IOUSBDevice is the
        // legacy alias. Scan both so we work across macOS versions.
        for className in ["IOUSBHostDevice", "IOUSBDevice"] {
            guard let matching = IOServiceMatching(className) else { continue }
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iter) }

            var service = IOIteratorNext(iter)
            while service != 0 {
                if intProperty(service, "idVendor") == samsungVID {
                    present = true
                    if let pid = intProperty(service, "idProduct"), downloadModePIDs.contains(pid) {
                        downloadMode = true
                    }
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iter)
            }
        }
        return (present, downloadMode)
    }

    private static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        guard let ref = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (ref.takeRetainedValue() as? NSNumber)?.intValue
    }
}
