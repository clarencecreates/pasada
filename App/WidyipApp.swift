import SwiftUI

@main
struct WidyipApp: App {
    init() {
        CrashReporter.shared.start()
        Log.app.info("Launch")
    }

    var body: some Scene {
        WindowGroup { PlacardLibraryView() }
    }
}
