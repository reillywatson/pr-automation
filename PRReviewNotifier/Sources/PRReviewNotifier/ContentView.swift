import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var monitor: PRMonitor

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if monitor.token.isEmpty {
                setupPrompt
            } else if monitor.isInitialLoading {
                loadingState
            } else if let err = monitor.lastError, !hasVisiblePRs {
                errorState(err)
            } else if !hasVisiblePRs {
                emptyState
            } else {
                prList
            }
            Divider()
            footer
        }
        .frame(width: 400)
    }

    private var hasVisiblePRs: Bool {
        !monitor.readyPRs.isEmpty || !monitor.snoozedPRs.isEmpty
    }

    // MARK: - Sub-views

    private var header: some View {
        HStack {
            Image(systemName: "bell.badge")
                .foregroundStyle(.tint)
            Text("PR Review Notifier")
                .font(.headline)
            Spacer()
            if monitor.isChecking {
                ProgressView().scaleEffect(0.7)
            }
            Button { Task { await monitor.checkPRs() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(monitor.isChecking)
            .help("Refresh now")
            Button { openSettings() } label: {
                Image(systemName: "gear")
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var setupPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Set up your GitHub token to start monitoring PRs.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Settings") { openSettings() }
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private func openSettings() {
        SettingsWindowController.shared.show(monitor: monitor)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("No PRs ready yet")
                .foregroundStyle(.secondary)
            Text("Waiting for all Copilot/Codex review comments to be addressed.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text("Loading PRs")
                .foregroundStyle(.secondary)
            Text("Checking review requests and Copilot/Codex comments.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private var prList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !monitor.readyPRs.isEmpty {
                    if !monitor.snoozedPRs.isEmpty {
                        sectionHeader("Ready")
                    }
                    ForEach(monitor.readyPRs) { pr in
                        PRRowView(pr: pr)
                            .environmentObject(monitor)
                        if pr != monitor.readyPRs.last {
                            Divider().padding(.leading, 44)
                        }
                    }
                }

                if !monitor.snoozedPRs.isEmpty {
                    if !monitor.readyPRs.isEmpty {
                        Divider()
                    }
                    sectionHeader("Snoozed")
                    ForEach(monitor.snoozedPRs) { pr in
                        PRRowView(pr: pr)
                            .environmentObject(monitor)
                        if pr != monitor.snoozedPRs.last {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 520)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            if let checked = monitor.lastChecked {
                Text("Checked \(checked, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

// MARK: - PR Row

struct PRRowView: View {
    @EnvironmentObject var monitor: PRMonitor
    let pr: ReadyPR
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.callout)
                        .foregroundStyle(.tint)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(pr.title)
                            .font(.callout)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(pr.repoName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(pr.reviewRequestReason)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if let reviewRequestedAt = pr.reviewRequestedAt {
                            Text("Requested \(reviewRequestedAt, style: .relative) ago")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        if let snoozedUntil = pr.snoozedUntil {
                            Text("Snoozed until \(snoozedUntil.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Button { monitor.ignore(pr) } label: {
                    Image(systemName: "eye.slash")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Ignore")

                Menu {
                    Button("20 minutes") {
                        monitor.snooze(pr, until: Date().addingTimeInterval(20 * 60))
                    }
                    Button("1 hour") {
                        monitor.snooze(pr, until: Date().addingTimeInterval(60 * 60))
                    }
                    Button("3 hours") {
                        monitor.snooze(pr, until: Date().addingTimeInterval(3 * 60 * 60))
                    }
                    Divider()
                    Button("Tomorrow at 9 AM") {
                        monitor.snooze(pr, until: PRMonitor.tomorrowAt9())
                    }
                    Button("Next week, Monday at 9 AM") {
                        monitor.snooze(pr, until: PRMonitor.nextWeekAt9())
                    }
                    Divider()
                    Button("Custom...") {
                        CustomSnoozeWindowController.shared.show(pr: pr, monitor: monitor)
                    }
                } label: {
                    Image(systemName: "clock")
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .help("Snooze")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private func open() {
        monitor.trackOpened(pr)
        if let url = URL(string: pr.url) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Custom Snooze

struct CustomSnoozeView: View {
    @EnvironmentObject var monitor: PRMonitor
    let pr: ReadyPR
    let onClose: () -> Void
    @State private var selectedDate: Date

    init(pr: ReadyPR, onClose: @escaping () -> Void) {
        self.pr = pr
        self.onClose = onClose
        _selectedDate = State(initialValue: pr.snoozedUntil ?? Date().addingTimeInterval(60 * 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Custom Snooze")
                .font(.title3.bold())

            DatePicker(
                "Remind me at",
                selection: $selectedDate,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.escape)
                Button("Snooze") {
                    monitor.snooze(pr, until: selectedDate)
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
        }
        .padding(22)
        .frame(width: 340)
    }
}

@MainActor
final class CustomSnoozeWindowController: NSObject, NSWindowDelegate {
    static let shared = CustomSnoozeWindowController()

    private var window: NSWindow?

    func show(pr: ReadyPR, monitor: PRMonitor) {
        window?.close()

        let view = CustomSnoozeView(pr: pr) { [weak self] in
            self?.close()
        }
        .environmentObject(monitor)

        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Snooze PR"
        window.contentViewController = hostingController
        let fittingSize = hostingController.sizeThatFits(
            in: NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude)
        )
        window.setContentSize(NSSize(width: 340, height: max(180, fittingSize.height)))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var monitor: PRMonitor
    let onClose: () -> Void
    @State private var tokenDraft = ""
    @State private var intervalMinutes = 2.0
    @State private var teamAllowlistDraft = ""
    @State private var titleExcludeRegexDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title2.bold())

            GroupBox("GitHub") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Personal Access Token")
                        .font(.callout)
                    SecureField("ghp_…", text: $tokenDraft)
                        .textFieldStyle(.roundedBorder)
                    Text("Needs **repo** scope (read access to pull requests and reviews).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            GroupBox("Team Review Requests") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Team allowlist")
                        .font(.callout)
                    TextEditor(text: $teamAllowlistDraft)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 72)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.25))
                        )
                    Text("One slug per line. Blank includes every team request; direct requests always notify.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            GroupBox("Title Exclude Regex") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Exclude matching PR titles")
                        .font(.callout)
                    TextField("e.g. ^WIP:|\\[skip review\\]", text: $titleExcludeRegexDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    if let titleExcludeRegexError {
                        Text("Invalid regex: \(titleExcludeRegexError)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Blank includes all PR titles.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }

            GroupBox("Polling") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Check interval: **\(Int(intervalMinutes)) min**")
                        .font(.callout)
                    Slider(value: $intervalMinutes, in: 1...60, step: 1)
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.escape)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(titleExcludeRegexError != nil)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            tokenDraft = monitor.token
            intervalMinutes = monitor.pollingInterval / 60
            teamAllowlistDraft = monitor.reviewTeamAllowlist.joined(separator: "\n")
            titleExcludeRegexDraft = monitor.titleExcludeRegexPattern
        }
    }

    private var titleExcludeRegexError: String? {
        PRMonitor.titleExcludeRegexValidationError(titleExcludeRegexDraft)
    }

    private func save() {
        monitor.pollingInterval = intervalMinutes * 60
        monitor.reviewTeamAllowlist = PRMonitor.parseTeamFilters(teamAllowlistDraft)
        monitor.titleExcludeRegexPattern = titleExcludeRegexDraft
        monitor.token = tokenDraft
        onClose()
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(monitor: PRMonitor) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView { [weak self] in
            self?.close()
        }
        .environmentObject(monitor)

        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "PR Review Notifier Settings"
        window.contentViewController = hostingController
        let fittingSize = hostingController.sizeThatFits(
            in: NSSize(width: 380, height: CGFloat.greatestFiniteMagnitude)
        )
        window.setContentSize(NSSize(width: 380, height: max(320, fittingSize.height)))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
        }
    }
}
