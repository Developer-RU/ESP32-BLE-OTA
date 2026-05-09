import SwiftUI

@main
struct ESP32_DFUApp: App {
    @StateObject private var manager = DFUSessionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
        }
    }
}
