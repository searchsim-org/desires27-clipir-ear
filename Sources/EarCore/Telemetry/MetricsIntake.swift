import Foundation
import GRDB

#if canImport(MetricKit) && os(iOS)
    import MetricKit
#endif

/// MetricKit intake (P8.5): daily metric and diagnostic payloads go into `device_metrics`; the raw JSON stays on the
/// phone and the export carries only the sums (Exporter `device_metrics`).
public final class MetricsIntake: NSObject, @unchecked Sendable {
    let store: SQLiteTranscriptStore
    public init(store: SQLiteTranscriptStore) { self.store = store }

    /// One row; also the test entry point (MetricKit payloads cannot be constructed in tests).
    public func record(
        kind: String, cpuSeconds: Double?, peakMemoryMB: Double?, hangs: Int, crashes: Int, json: Data
    ) async throws {
        let text = String(decoding: json, as: UTF8.self)
        try await store.db.write {
            try $0.execute(
                sql: """
                    INSERT INTO device_metrics (received_at, kind, cpu_seconds, peak_memory_mb, hangs, crashes, json)
                    VALUES (?,?,?,?,?,?,?)
                    """,
                arguments: [Date().timeIntervalSince1970, kind, cpuSeconds, peakMemoryMB, hangs, crashes, text])
        }
    }
}

#if canImport(MetricKit) && os(iOS)
    extension MetricsIntake: MXMetricManagerSubscriber {
        public func start() { MXMetricManager.shared.add(self) }

        public func didReceive(_ payloads: [MXMetricPayload]) {
            for p in payloads {
                let cpu = p.cpuMetrics?.cumulativeCPUTime.converted(to: .seconds).value
                let mem = p.memoryMetrics?.peakMemoryUsage.converted(to: .megabytes).value
                let json = p.jsonRepresentation()
                Task {
                    try? await record(
                        kind: "metrics", cpuSeconds: cpu, peakMemoryMB: mem, hangs: 0, crashes: 0, json: json)
                }
            }
        }

        public func didReceive(_ payloads: [MXDiagnosticPayload]) {
            for p in payloads {
                let (hangs, crashes) = (p.hangDiagnostics?.count ?? 0, p.crashDiagnostics?.count ?? 0)
                let json = p.jsonRepresentation()
                Task {
                    try? await record(
                        kind: "diagnostics", cpuSeconds: nil, peakMemoryMB: nil, hangs: hangs, crashes: crashes,
                        json: json)
                }
            }
        }
    }
#endif
