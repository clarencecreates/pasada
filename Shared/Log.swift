import os
import Foundation

/// App-wide loggers. Unified logging persists on device, so entries survive
/// relaunches and appear in Console.app and sysdiagnoses.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.cyrillepardinas.widyip"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let crash = Logger(subsystem: subsystem, category: "crash")
}
