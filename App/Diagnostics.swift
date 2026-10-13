import Foundation
import MetricKit
import os

/// Crash and hang reporting through MetricKit. The system delivers diagnostics
/// (crashes, hangs, CPU and disk exceptions) on the next launch; each payload
/// is logged and written to `Library/Diagnostics/` so it can be inspected or
/// uploaded later. TestFlight and App Store crashes also appear in Xcode's
/// Organizer without any extra work.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    private let directory: URL? = {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let folder = library.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    func start() {
        MXMetricManager.shared.add(self)
        // Diagnostics delivered while the app was not running.
        didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            Log.crash.error("Diagnostic payload: \(crashes) crash(es), \(hangs) hang(s)")
            save(payload.jsonRepresentation(), named: "diagnostic")
        }
    }

    private func save(_ data: Data, named prefix: String) {
        guard let directory else { return }
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(prefix)-\(stamp)-\(UUID().uuidString.prefix(6)).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Log.crash.error("Couldn't save diagnostic: \(error.localizedDescription)")
        }
    }
}
