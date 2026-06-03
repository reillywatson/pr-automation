import SwiftUI
import AppKit

// Hide the Dock icon — this runs as a menu bar agent only.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct PRReviewNotifierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor = PRMonitor()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        if monitor.readyPRs.isEmpty {
            Image(systemName: "bell")
        } else {
            HStack(spacing: 4) {
                Image(systemName: "bell.badge.fill")
                Text("\(monitor.readyPRs.count)")
                    .font(.caption.bold())
            }
        }
    }
}
