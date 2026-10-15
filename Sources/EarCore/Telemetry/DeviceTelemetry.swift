@preconcurrency import Darwin  // mach_task_self_ is a C global
import Foundation
import Synchronization

#if canImport(UIKit)
    import UIKit
#endif

/// Thermal state, memory footprint and battery (P4.5), sampled during queries; stored as latency_json extras.
public enum DeviceTelemetry {
    public static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// Physical footprint in MB (what jetsam counts), via task_vm_info.
    public static var footprintMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// 0…1, or nil where unavailable (macOS, simulator).
    @MainActor public static var batteryLevel: Double? {
        #if canImport(UIKit) && !targetEnvironment(simulator)
            UIDevice.current.isBatteryMonitoringEnabled = true
            let l = UIDevice.current.batteryLevel
            return l < 0 ? nil : Double(l)
        #else
            return nil
        #endif
    }
}

/// Samples footprint every `interval` while a query runs; `finish()` returns the peak in MB.
final class FootprintSampler: Sendable {
    final class Peak: Sendable {
        let mb = Mutex(0.0)
        func record() { mb.withLock { $0 = max($0, DeviceTelemetry.footprintMB) } }
    }
    private let peak = Peak()
    private let task: Task<Void, Never>

    init(interval: Duration = .seconds(5)) {
        let peak = peak
        task = Task.detached {
            while !Task.isCancelled {
                peak.record()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func finish() -> Double {
        task.cancel()
        peak.record()
        return peak.mb.withLock { $0 }
    }
}
