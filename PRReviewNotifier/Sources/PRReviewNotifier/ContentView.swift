import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var monitor: PRMonitor
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if monitor.token.isEmpty {
                setupPrompt
            } else if let err = monitor.lastError, monitor.readyPRs.isEmpty {
                errorState(err)
            } else if monitor.readyPRs.isEmpty {
                emptyState
            } else {
                prList
            }
            Divider()
            footer
        }
        .frame(width: 400)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(monitor)
        }
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
            Button { showSettings = true } label: {
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
            Button("Open Settings") { showSettings = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
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

    private var prList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(monitor.readyPRs) { pr in
                    PRRowView(pr: pr)
                    if pr != monitor.readyPRs.last {
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
        .frame(maxHeight: 440)
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
    let pr: ReadyPR
    @State private var isHovered = false

    var body: some View {
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
                }

                Spacer()

                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func open() {
        if let url = URL(string: pr.url) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var monitor: PRMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var tokenDraft = ""
    @State private var intervalMinutes = 5.0

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
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            tokenDraft = monitor.token
            intervalMinutes = monitor.pollingInterval / 60
        }
    }

    private func save() {
        monitor.pollingInterval = intervalMinutes * 60
        monitor.token = tokenDraft   // setting token triggers a refresh
        dismiss()
    }
}
