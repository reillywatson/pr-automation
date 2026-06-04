import SwiftUI
import AppKit

// Hide the Dock icon — this runs as a menu bar agent only.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = PRMonitor()
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationManager.shared.configure()
        statusBarController = StatusBarController(monitor: monitor)
    }
}

@main
struct PRReviewNotifierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
