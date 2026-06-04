import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let monitor: PRMonitor
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let loadingIndicator: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.isDisplayedWhenStopped = false
        indicator.isHidden = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()
    private var cancellables = Set<AnyCancellable>()

    init(monitor: PRMonitor) {
        self.monitor = monitor
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        configurePopover()
        configureStatusButton()
        bindMonitor()
        updateStatusButton()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 400, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: ContentView().environmentObject(monitor)
        )
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageLeft
        button.alignment = .center

        button.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            loadingIndicator.widthAnchor.constraint(equalToConstant: 16),
            loadingIndicator.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    private func bindMonitor() {
        monitor.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateStatusButton()
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }

        let title: String
        let accessibilityDescription: String

        if monitor.isInitialLoading {
            button.image = nil
            button.title = ""
            button.toolTip = "PR Review Notifier loading"
            loadingIndicator.isHidden = false
            loadingIndicator.startAnimation(nil)
            statusItem.length = NSStatusItem.squareLength
            return
        } else {
            loadingIndicator.stopAnimation(nil)
            loadingIndicator.isHidden = true
        }

        let symbolName: String
        if monitor.readyPRs.isEmpty {
            symbolName = "bell"
            title = ""
            accessibilityDescription = "PR Review Notifier"
        } else {
            symbolName = "bell.badge.fill"
            title = " \(monitor.readyPRs.count)"
            accessibilityDescription = "\(monitor.readyPRs.count) PRs ready for review"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
            ?? NSImage(systemSymbolName: "bell", accessibilityDescription: accessibilityDescription)
        image?.isTemplate = true
        button.image = image
        button.title = title
        button.toolTip = accessibilityDescription
        statusItem.length = title.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        clearPopoverFocusAfterLayout()
    }

    private func clearPopoverFocusAfterLayout() {
        DispatchQueue.main.async { [weak self] in
            self?.popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
    }
}
