import Foundation
import AppKit

@MainActor
class PRMonitor: ObservableObject {
    @Published var readyPRs: [ReadyPR] = []
    @Published var lastError: String?
    @Published var lastChecked: Date?
    @Published var isChecking = false

    private var timer: Timer?
    // Persisted so we don't re-notify after relaunch for PRs that were already ready
    private var notifiedIDs: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: "notified_pr_ids") as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "notified_pr_ids") }
    }

    var token: String {
        get { UserDefaults.standard.string(forKey: "github_token") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "github_token")
            cachedUsername = nil
            Task { await checkPRs() }
        }
    }

    var pollingInterval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: "polling_interval")
            return stored > 0 ? stored : 300
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "polling_interval")
            scheduleTimer()
        }
    }

    private var cachedUsername: String?

    init() {
        scheduleTimer()
        if !token.isEmpty {
            Task { await checkPRs() }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkPRs() }
        }
    }

    func checkPRs() async {
        guard !token.isEmpty else {
            lastError = "Enter a GitHub token in Settings to get started."
            return
        }

        isChecking = true
        lastError = nil
        defer { isChecking = false }

        let service = GitHubService(token: token)

        do {
            if cachedUsername == nil {
                cachedUsername = try await service.getCurrentUser().login
            }
            guard let username = cachedUsername else { return }

            let issues = try await service.getPRsRequestingReview(username: username)
            var newReady: [ReadyPR] = []

            for issue in issues {
                let parts = issue.repoFullName.split(separator: "/")
                guard parts.count == 2 else { continue }
                let owner = String(parts[0])
                let repo = String(parts[1])

                if try await isReady(service: service, owner: owner, repo: repo, issue: issue) {
                    newReady.append(ReadyPR(
                        id: issue.number,
                        title: issue.title,
                        repoName: issue.repoFullName,
                        url: issue.htmlURL
                    ))
                }
            }

            // Notify for PRs that are newly ready
            var ids = notifiedIDs
            let currentlyReadyIDs = Set(newReady.map(\.id))
            for pr in newReady where !ids.contains(pr.id) {
                notify(pr)
                ids.insert(pr.id)
            }
            // Prune IDs for PRs no longer in the ready set (so we re-notify if they become ready again)
            ids = ids.intersection(currentlyReadyIDs)
            notifiedIDs = ids

            readyPRs = newReady
            lastChecked = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func isReady(
        service: GitHubService,
        owner: String,
        repo: String,
        issue: SearchIssue
    ) async throws -> Bool {
        let reviews = try await service.getReviews(owner: owner, repo: repo, number: issue.number)
        let aiReviews = reviews.filter(\.isFromAIBot)
        guard !aiReviews.isEmpty else { return false }

        let aiReviewIDs = Set(aiReviews.map(\.id))
        let allComments = try await service.getReviewComments(owner: owner, repo: repo, number: issue.number)

        // Comments belonging to AI-authored reviews
        let aiComments = allComments.filter { c in
            if let reviewID = c.pullRequestReviewId {
                return aiReviewIDs.contains(reviewID)
            }
            // Fallback: match by commenter login if review ID is missing
            return c.user?.login.lowercased().contains("copilot") == true
                || c.user?.login.lowercased().contains("codex") == true
        }

        // A review with no inline comments is trivially satisfied
        if aiComments.isEmpty { return true }

        // Build the set of comment IDs that have received at least one reply
        let repliedToIDs = Set(allComments.compactMap(\.inReplyToId))

        return aiComments.allSatisfy { comment in
            comment.isOutdated || repliedToIDs.contains(comment.id)
        }
    }

    private func notify(_ pr: ReadyPR) {
        let title = pr.title.replacingOccurrences(of: "\"", with: "'")
        let repo = pr.repoName
        let script = """
        display notification "\(title)" with title "PR Ready for Review" subtitle "\(repo)"
        """
        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-e", script]
        try? proc.run()
    }
}
