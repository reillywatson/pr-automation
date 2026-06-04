import Foundation

enum PRActionKind: String, Codable {
    case ignored
    case snoozed
}

struct PRActionStatus: Codable {
    let kind: PRActionKind
    let snoozedUntil: Date?
    let resetFingerprint: String
    let createdAt: Date
}

private struct ReviewRequestInfo {
    let reason: String
    let sourceKeys: Set<String>
}

private struct PRReference {
    let owner: String
    let repo: String
    let number: Int
}

@MainActor
class PRMonitor: ObservableObject {
    @Published var readyPRs: [ReadyPR] = []
    @Published var snoozedPRs: [ReadyPR] = []
    @Published var lastError: String?
    @Published var lastChecked: Date?
    @Published var isChecking = false
    @Published var hasLoadedOnce = false

    var isInitialLoading: Bool {
        isChecking && !hasLoadedOnce
    }

    private var timer: Timer?
    private var recentlyOpenedTimer: Timer?
    private var recentlyOpenedPRDeadlines: [String: Date] = [:]
    private var recentlyCompletedPRDeadlines: [String: Date] = [:]
    private var isCheckingRecentlyOpened = false
    private let recentlyOpenedPollInterval: TimeInterval = 15
    private let recentlyOpenedWatchDuration: TimeInterval = 5 * 60
    private let recentlyOpenedPollLimit = 4
    private let recentlyCompletedGracePeriod: TimeInterval = 3 * 60

    // Persisted so we don't re-notify after relaunch for PRs that were already ready
    private var notifiedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "notified_pr_ids") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "notified_pr_ids") }
    }

    private var prActionStatuses: [String: PRActionStatus] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "pr_action_statuses") else { return [:] }
            return (try? JSONDecoder().decode([String: PRActionStatus].self, from: data)) ?? [:]
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: "pr_action_statuses")
        }
    }

    var token: String {
        get { UserDefaults.standard.string(forKey: "github_token") ?? "" }
        set {
            let previousValue = token
            UserDefaults.standard.set(newValue, forKey: "github_token")
            guard newValue != previousValue else { return }
            cachedUsername = nil
            Task { await checkPRs() }
        }
    }

    var reviewTeamAllowlist: [String] {
        get { UserDefaults.standard.stringArray(forKey: "review_team_allowlist") ?? [] }
        set {
            let normalizedValue = Self.normalizeTeamFilters(newValue)
            guard normalizedValue != reviewTeamAllowlist else { return }
            UserDefaults.standard.set(normalizedValue, forKey: "review_team_allowlist")
            Task { await checkPRs() }
        }
    }

    var titleExcludeRegexPattern: String {
        get { UserDefaults.standard.string(forKey: "title_exclude_regex") ?? "" }
        set {
            let newlineTrimmedValue = newValue.trimmingCharacters(in: .newlines)
            let normalizedValue = newlineTrimmedValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? "" : newlineTrimmedValue
            guard normalizedValue != titleExcludeRegexPattern else { return }
            UserDefaults.standard.set(normalizedValue, forKey: "title_exclude_regex")

            if let regex = Self.compileTitleExcludeRegex(normalizedValue) {
                readyPRs.removeAll { Self.title($0.title, matches: regex) }
                snoozedPRs.removeAll { Self.title($0.title, matches: regex) }
            }

            Task { await checkPRs() }
        }
    }

    var pollingInterval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: "polling_interval")
            return stored > 0 ? stored : 120
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

    deinit {
        timer?.invalidate()
        recentlyOpenedTimer?.invalidate()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkPRs() }
        }
    }

    func checkPRs() async {
        guard !token.isEmpty else {
            readyPRs = []
            snoozedPRs = []
            hasLoadedOnce = false
            lastError = "Enter a GitHub token in Settings to get started."
            return
        }
        guard !isChecking else { return }

        let tokenAtStart = token
        isChecking = true
        lastError = nil
        defer { isChecking = false }

        let service = GitHubService(token: tokenAtStart)

        do {
            if cachedUsername == nil {
                cachedUsername = try await service.getCurrentUser().login
            }
            guard let username = cachedUsername else { return }

            let issues = try await service.getPRsRequestingReview(username: username)
            let titleExcludeRegex = Self.compileTitleExcludeRegex(titleExcludeRegexPattern)
            let filteredIssues = issues.filter { issue in
                !Self.title(issue.title, matches: titleExcludeRegex)
            }
            let summaries = try await service.getPullRequestSummaries(for: filteredIssues)
            var newReady: [ReadyPR] = []
            var newSnoozed: [ReadyPR] = []
            let initialStatuses = prActionStatuses
            var statuses = initialStatuses
            var removedStatusIDs = Set<String>()
            var renotifyIDs = Set<String>()
            let now = Date()

            for summary in summaries {
                let parts = summary.repoFullName.split(separator: "/")
                guard parts.count == 2 else { continue }
                let owner = String(parts[0])
                let repo = String(parts[1])
                let prID = summary.id

                let storedStatus = statuses[prID]
                var requestInfo: ReviewRequestInfo?
                var fingerprint: String?
                var reviewRequestedAt: Date?
                var status: PRActionStatus?

                if storedStatus != nil {
                    let details = try await service.getPullRequest(
                        owner: owner,
                        repo: repo,
                        number: summary.number
                    )
                    requestInfo = reviewRequestInfo(
                        details: details,
                        owner: owner,
                        username: username
                    )
                    guard let requestInfo else {
                        statuses[prID] = nil
                        removedStatusIDs.insert(prID)
                        continue
                    }
                    let issueEvents = try await service.getIssueEvents(
                        owner: owner,
                        repo: repo,
                        number: summary.number
                    )
                    reviewRequestedAt = latestReviewRequestDate(
                        issueEvents,
                        owner: owner,
                        requestInfo: requestInfo
                    )
                    let computedFingerprint = try await activityFingerprint(
                        service: service,
                        owner: owner,
                        repo: repo,
                        number: summary.number,
                        username: username,
                        requestInfo: requestInfo,
                        issueEvents: issueEvents,
                        reviewThreads: summary.reviewThreads
                    )
                    fingerprint = computedFingerprint
                    status = currentStatus(
                        for: prID,
                        fingerprint: computedFingerprint,
                        statuses: &statuses,
                        removedStatusIDs: &removedStatusIDs,
                        renotifyIDs: &renotifyIDs
                    )
                }

                guard isReady(
                    reviews: summary.reviews,
                    reviewThreads: summary.reviewThreads
                ) else { continue }

                if requestInfo == nil {
                    let details = try await service.getPullRequest(
                        owner: owner,
                        repo: repo,
                        number: summary.number
                    )
                    requestInfo = reviewRequestInfo(
                        details: details,
                        owner: owner,
                        username: username
                    )
                }
                guard let requestInfo else { continue }
                if reviewRequestedAt == nil {
                    let issueEvents = try await service.getIssueEvents(
                        owner: owner,
                        repo: repo,
                        number: summary.number
                    )
                    reviewRequestedAt = latestReviewRequestDate(
                        issueEvents,
                        owner: owner,
                        requestInfo: requestInfo
                    )
                }
                let resolvedFingerprint = fingerprint ?? deferredFingerprint(requestInfo: requestInfo)

                let pr = ReadyPR(
                    id: prID,
                    title: summary.title,
                    repoName: summary.repoFullName,
                    reviewRequestReason: requestInfo.reason,
                    reviewRequestedAt: reviewRequestedAt,
                    activityFingerprint: resolvedFingerprint,
                    snoozedUntil: nil,
                    url: summary.htmlURL
                )

                switch status?.kind {
                case .ignored:
                    continue
                case .snoozed:
                    if let snoozedUntil = status?.snoozedUntil, snoozedUntil > now {
                        newSnoozed.append(pr.snoozed(until: snoozedUntil))
                        continue
                    }
                    statuses[prID] = nil
                    removedStatusIDs.insert(prID)
                    renotifyIDs.insert(prID)
                    newReady.append(pr)
                case nil:
                    newReady.append(pr)
                }
            }

            guard token == tokenAtStart else { return }

            var persistedStatuses = prActionStatuses
            for prID in removedStatusIDs {
                if persistedStatuses[prID]?.resetFingerprint == initialStatuses[prID]?.resetFingerprint {
                    persistedStatuses[prID] = nil
                }
            }
            prActionStatuses = persistedStatuses

            let filteredLists = applyLatestStatuses(
                readyPRs: newReady,
                snoozedPRs: newSnoozed,
                statuses: persistedStatuses,
                now: now
            )
            newReady = filteredLists.ready
            newSnoozed = filteredLists.snoozed
            pruneRecentlyCompletedPRs(now: now)
            newReady.removeAll { recentlyCompletedPRDeadlines[$0.id, default: .distantPast] > now }
            newSnoozed.removeAll { recentlyCompletedPRDeadlines[$0.id, default: .distantPast] > now }

            // Notify for PRs that are newly ready
            var ids = notifiedIDs
            ids.subtract(renotifyIDs)
            let currentlyReadyIDs = Set(newReady.map(\.id))
            for pr in newReady where !ids.contains(pr.id) {
                notify(pr)
                ids.insert(pr.id)
            }
            // Prune IDs for PRs no longer in the ready set (so we re-notify if they become ready again)
            ids = ids.intersection(currentlyReadyIDs)
            notifiedIDs = ids

            readyPRs = newReady
            snoozedPRs = newSnoozed.sorted {
                ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture)
            }
            lastChecked = Date()
            hasLoadedOnce = true
        } catch {
            lastError = error.localizedDescription
            hasLoadedOnce = true
        }
    }

    private func reviewRequestInfo(
        details: PullRequestDetails,
        owner: String,
        username: String
    ) -> ReviewRequestInfo? {
        reviewRequestInfo(
            requestedReviewers: details.requestedReviewers,
            requestedTeams: details.requestedTeams,
            owner: owner,
            username: username
        )
    }

    private func reviewRequestInfo(
        requestedReviewers: [BotUser],
        requestedTeams allRequestedTeams: [RequestedTeam],
        owner: String,
        username: String
    ) -> ReviewRequestInfo? {
        let normalizedUsername = username.lowercased()
        var reasons: [String] = []
        var sourceKeys = Set<String>()

        if requestedReviewers.contains(where: { $0.login.lowercased() == normalizedUsername }) {
            reasons.append("@\(username)")
            sourceKeys.insert("user:\(normalizedUsername)")
        }

        let allowedTeams = Set(reviewTeamAllowlist)
        let requestedTeams: [RequestedTeam]
        if allowedTeams.isEmpty {
            requestedTeams = allRequestedTeams
        } else {
            let normalizedOwner = owner.lowercased()
            requestedTeams = allRequestedTeams.filter { team in
                allowedTeams.contains(team.slug.lowercased())
                    || allowedTeams.contains("\(normalizedOwner)/\(team.slug.lowercased())")
                    || allowedTeams.contains(team.name.lowercased())
            }
        }

        for team in requestedTeams {
            let teamKey = "team:\(owner.lowercased())/\(team.slug.lowercased())"
            reasons.append("@\(owner)/\(team.slug)")
            sourceKeys.insert(teamKey)
        }

        guard !reasons.isEmpty else { return nil }
        return ReviewRequestInfo(
            reason: "Requested: \(reasons.joined(separator: ", "))",
            sourceKeys: sourceKeys
        )
    }

    private func activityFingerprint(
        service: GitHubService,
        owner: String,
        repo: String,
        number: Int,
        username: String,
        requestInfo: ReviewRequestInfo,
        issueEvents: [IssueEvent],
        reviewThreads: [ReviewThread]
    ) async throws -> String {
        let issueComments = try await service.getIssueComments(owner: owner, repo: repo, number: number)
        let latestReviewRequest = issueEvents
            .filter { eventMatchesCurrentReviewRequest($0, owner: owner, sourceKeys: requestInfo.sourceKeys) }
            .max { $0.id < $1.id }
        let latestIssueMention = issueComments
            .filter { containsMention($0.body, username: username) }
            .max { $0.id < $1.id }
        let latestReviewMention = reviewThreads
            .flatMap(\.comments.nodes)
            .filter { containsMention($0.body, username: username) }
            .max { ($0.databaseId ?? 0) < ($1.databaseId ?? 0) }

        let requestKey = latestReviewRequest.map { "\($0.id):\($0.createdAt ?? "")" }
            ?? requestInfo.sourceKeys.sorted().joined(separator: ",")
        let issueMentionKey = latestIssueMention.map { "\($0.id):\($0.updatedAt ?? $0.createdAt ?? "")" } ?? "none"
        let reviewMentionKey = latestReviewMention.map {
            "\($0.databaseId ?? 0):\($0.updatedAt ?? $0.createdAt ?? "")"
        } ?? "none"

        return "request=\(requestKey)|issueMention=\(issueMentionKey)|reviewMention=\(reviewMentionKey)"
    }

    private func latestReviewRequestDate(
        _ issueEvents: [IssueEvent],
        owner: String,
        requestInfo: ReviewRequestInfo
    ) -> Date? {
        let latestReviewRequest = issueEvents
            .filter { eventMatchesCurrentReviewRequest($0, owner: owner, sourceKeys: requestInfo.sourceKeys) }
            .max { $0.id < $1.id }

        return parseGitHubDate(latestReviewRequest?.createdAt)
    }

    private func parseGitHubDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private func deferredFingerprint(requestInfo: ReviewRequestInfo) -> String {
        "deferred=\(requestInfo.sourceKeys.sorted().joined(separator: ","))"
    }

    private func eventMatchesCurrentReviewRequest(
        _ event: IssueEvent,
        owner: String,
        sourceKeys: Set<String>
    ) -> Bool {
        guard event.event == "review_requested" else { return false }
        if let reviewer = event.requestedReviewer {
            return sourceKeys.contains("user:\(reviewer.login.lowercased())")
        }
        if let team = event.requestedTeam {
            return sourceKeys.contains("team:\(owner.lowercased())/\(team.slug.lowercased())")
        }
        return false
    }

    private func containsMention(_ body: String, username: String) -> Bool {
        body.range(of: "@\(username)", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func currentStatus(
        for prID: String,
        fingerprint: String,
        statuses: inout [String: PRActionStatus],
        removedStatusIDs: inout Set<String>,
        renotifyIDs: inout Set<String>
    ) -> PRActionStatus? {
        guard let status = statuses[prID] else { return nil }
        guard status.resetFingerprint == fingerprint else {
            statuses[prID] = nil
            removedStatusIDs.insert(prID)
            renotifyIDs.insert(prID)
            return nil
        }
        return status
    }

    private func isReady(
        reviews: [Review],
        reviewThreads: [ReviewThread]
    ) -> Bool {
        let aiReviews = reviews.filter(\.isFromAIBot)
        guard !aiReviews.isEmpty else { return false }

        let aiReviewIDs = Set(aiReviews.map(\.id))
        let aiThreads = reviewThreads.filter { thread in
            thread.comments.nodes.contains { comment in
                if let reviewID = comment.pullRequestReview?.databaseId {
                    return aiReviewIDs.contains(reviewID)
                }
                return isAIBotLogin(comment.author?.login)
                    || isAIBotLogin(comment.pullRequestReview?.author?.login)
            }
        }

        if !aiThreads.isEmpty {
            return aiThreads.allSatisfy { thread in
                thread.isResolved || thread.isOutdated || hasNonAIReply(in: thread)
            }
        }

        // A review with no inline threads is trivially satisfied.
        return true
    }

    private func hasNonAIReply(in thread: ReviewThread) -> Bool {
        let comments = thread.comments.nodes
        guard let firstAIIndex = comments.firstIndex(where: { comment in
            isAIBotLogin(comment.author?.login)
                || isAIBotLogin(comment.pullRequestReview?.author?.login)
        }) else {
            return false
        }

        return comments.dropFirst(firstAIIndex + 1).contains { comment in
            !isAIBotLogin(comment.author?.login)
        }
    }

    private func isAIBotLogin(_ login: String?) -> Bool {
        guard let login = login?.lowercased() else { return false }
        return login.contains("copilot") || login.contains("codex") || login.contains("openai")
    }

    func trackOpened(_ pr: ReadyPR) {
        guard prReference(from: pr) != nil else { return }
        recentlyOpenedPRDeadlines[pr.id] = Date().addingTimeInterval(recentlyOpenedWatchDuration)
        scheduleRecentlyOpenedTimer()
    }

    private func scheduleRecentlyOpenedTimer() {
        guard recentlyOpenedTimer == nil else { return }
        recentlyOpenedTimer = Timer.scheduledTimer(withTimeInterval: recentlyOpenedPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkRecentlyOpenedPRs() }
        }
    }

    private func stopRecentlyOpenedTimerIfIdle() {
        guard recentlyOpenedPRDeadlines.isEmpty else { return }
        recentlyOpenedTimer?.invalidate()
        recentlyOpenedTimer = nil
    }

    private func checkRecentlyOpenedPRs() async {
        guard !isCheckingRecentlyOpened else { return }
        guard !token.isEmpty else {
            recentlyOpenedPRDeadlines = [:]
            stopRecentlyOpenedTimerIfIdle()
            return
        }

        isCheckingRecentlyOpened = true
        defer {
            isCheckingRecentlyOpened = false
            stopRecentlyOpenedTimerIfIdle()
        }

        let now = Date()
        recentlyOpenedPRDeadlines = recentlyOpenedPRDeadlines.filter { $0.value > now }
        guard !recentlyOpenedPRDeadlines.isEmpty else { return }

        let idsToCheck = recentlyOpenedPRDeadlines
            .sorted { $0.value < $1.value }
            .prefix(recentlyOpenedPollLimit)
            .map(\.key)

        let service = GitHubService(token: token)

        do {
            if cachedUsername == nil {
                cachedUsername = try await service.getCurrentUser().login
            }
            guard let username = cachedUsername else { return }

            for prID in idsToCheck {
                try await checkRecentlyOpenedPR(
                    id: prID,
                    service: service,
                    username: username
                )
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func checkRecentlyOpenedPR(
        id prID: String,
        service: GitHubService,
        username: String
    ) async throws {
        guard let pr = (readyPRs + snoozedPRs).first(where: { $0.id == prID }),
              let reference = prReference(from: pr) else {
            recentlyOpenedPRDeadlines[prID] = nil
            return
        }

        let details = try await service.getPullRequest(
            owner: reference.owner,
            repo: reference.repo,
            number: reference.number
        )

        guard let requestInfo = reviewRequestInfo(
            details: details,
            owner: reference.owner,
            username: username
        ) else {
            completeRecentlyOpenedPR(prID)
            return
        }

        let issueEvents = try await service.getIssueEvents(
            owner: reference.owner,
            repo: reference.repo,
            number: reference.number
        )
        let reviews = try await service.getReviews(
            owner: reference.owner,
            repo: reference.repo,
            number: reference.number
        )

        if userHasReviewedAfterLatestRequest(
            reviews: reviews,
            issueEvents: issueEvents,
            owner: reference.owner,
            username: username,
            requestInfo: requestInfo
        ) {
            completeRecentlyOpenedPR(prID)
        }
    }

    private func userHasReviewedAfterLatestRequest(
        reviews: [Review],
        issueEvents: [IssueEvent],
        owner: String,
        username: String,
        requestInfo: ReviewRequestInfo
    ) -> Bool {
        let latestReviewRequestAt = issueEvents
            .filter { eventMatchesCurrentReviewRequest($0, owner: owner, sourceKeys: requestInfo.sourceKeys) }
            .compactMap(\.createdAt)
            .max()

        guard let latestReviewRequestAt else {
            return false
        }

        let completedReviewStates = Set(["APPROVED", "CHANGES_REQUESTED", "COMMENTED"])
        let latestOwnReviewAt = reviews
            .filter {
                $0.user?.login.lowercased() == username.lowercased()
                    && completedReviewStates.contains($0.state.uppercased())
            }
            .compactMap(\.submittedAt)
            .max()

        return latestOwnReviewAt.map { $0 > latestReviewRequestAt } ?? false
    }

    private func completeRecentlyOpenedPR(_ prID: String) {
        recentlyOpenedPRDeadlines[prID] = nil
        recentlyCompletedPRDeadlines[prID] = Date().addingTimeInterval(recentlyCompletedGracePeriod)
        readyPRs.removeAll { $0.id == prID }
        snoozedPRs.removeAll { $0.id == prID }
        forgetNotification(for: prID)
    }

    private func pruneRecentlyCompletedPRs(now: Date = Date()) {
        recentlyCompletedPRDeadlines = recentlyCompletedPRDeadlines.filter { $0.value > now }
    }

    private func notify(_ pr: ReadyPR) {
        NotificationManager.shared.notify(pr: pr)
    }

    func ignore(_ pr: ReadyPR) {
        Task { await setActionStatus(.ignored, for: pr, snoozedUntil: nil) }
    }

    func snooze(_ pr: ReadyPR, until date: Date) {
        Task { await setActionStatus(.snoozed, for: pr, snoozedUntil: date) }
    }

    private func setActionStatus(_ kind: PRActionKind, for pr: ReadyPR, snoozedUntil: Date?) async {
        let fingerprint: String
        do {
            fingerprint = try await currentActivityFingerprint(for: pr)
        } catch {
            lastError = error.localizedDescription
            return
        }

        var statuses = prActionStatuses
        statuses[pr.id] = PRActionStatus(
            kind: kind,
            snoozedUntil: snoozedUntil,
            resetFingerprint: fingerprint,
            createdAt: Date()
        )
        prActionStatuses = statuses
        forgetNotification(for: pr.id)

        readyPRs.removeAll { $0.id == pr.id }
        snoozedPRs.removeAll { $0.id == pr.id }

        if kind == .snoozed, let snoozedUntil {
            if snoozedUntil > Date() {
                snoozedPRs.append(pr.snoozed(until: snoozedUntil))
                snoozedPRs.sort {
                    ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture)
                }
            } else {
                readyPRs.append(pr.unsnoozed())
            }
        }
    }

    private func currentActivityFingerprint(for pr: ReadyPR) async throws -> String {
        guard let reference = prReference(from: pr) else {
            return pr.activityFingerprint
        }

        let service = GitHubService(token: token)
        if cachedUsername == nil {
            cachedUsername = try await service.getCurrentUser().login
        }
        guard let username = cachedUsername else {
            return pr.activityFingerprint
        }

        let details = try await service.getPullRequest(
            owner: reference.owner,
            repo: reference.repo,
            number: reference.number
        )
        guard let requestInfo = reviewRequestInfo(
            details: details,
            owner: reference.owner,
            username: username
        ) else {
            return pr.activityFingerprint
        }
        let reviewThreads = try await service.getReviewThreads(
            owner: reference.owner,
            repo: reference.repo,
            number: reference.number
        )
        let issueEvents = try await service.getIssueEvents(
            owner: reference.owner,
            repo: reference.repo,
            number: reference.number
        )

        return try await activityFingerprint(
            service: service,
            owner: reference.owner,
            repo: reference.repo,
            number: reference.number,
            username: username,
            requestInfo: requestInfo,
            issueEvents: issueEvents,
            reviewThreads: reviewThreads
        )
    }

    private func prReference(from pr: ReadyPR) -> PRReference? {
        let idParts = pr.id.split(separator: "#", maxSplits: 1)
        guard idParts.count == 2,
              let number = Int(idParts[1]) else {
            return nil
        }

        let repoParts = idParts[0].split(separator: "/", maxSplits: 1)
        guard repoParts.count == 2 else { return nil }

        return PRReference(
            owner: String(repoParts[0]),
            repo: String(repoParts[1]),
            number: number
        )
    }

    private func applyLatestStatuses(
        readyPRs: [ReadyPR],
        snoozedPRs: [ReadyPR],
        statuses: [String: PRActionStatus],
        now: Date
    ) -> (ready: [ReadyPR], snoozed: [ReadyPR]) {
        var ready: [ReadyPR] = []
        var snoozed: [ReadyPR] = []
        var seenIDs = Set<String>()

        for pr in readyPRs + snoozedPRs {
            guard seenIDs.insert(pr.id).inserted else { continue }
            let activePR = pr.unsnoozed()

            switch statuses[pr.id]?.kind {
            case .ignored:
                continue
            case .snoozed:
                if let snoozedUntil = statuses[pr.id]?.snoozedUntil, snoozedUntil > now {
                    snoozed.append(activePR.snoozed(until: snoozedUntil))
                } else {
                    ready.append(activePR)
                }
            case nil:
                ready.append(activePR)
            }
        }

        return (ready, snoozed)
    }

    private func forgetNotification(for prID: String) {
        var ids = notifiedIDs
        ids.remove(prID)
        notifiedIDs = ids
    }

    static func tomorrowAt9(from date: Date = Date()) -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    static func nextWeekAt9(from date: Date = Date()) -> Date {
        let calendar = Calendar.current
        let nextWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: date) ?? date.addingTimeInterval(604_800)
        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: nextWeek)
        components.weekday = 2
        components.hour = 9
        components.minute = 0
        components.second = 0
        return calendar.date(from: components) ?? nextWeek
    }

    static func parseTeamFilters(_ text: String) -> [String] {
        normalizeTeamFilters(text.components(separatedBy: CharacterSet(charactersIn: ",\n")))
    }

    static func titleExcludeRegexValidationError(_ pattern: String) -> String? {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else { return nil }

        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func compileTitleExcludeRegex(_ pattern: String) -> NSRegularExpression? {
        guard titleExcludeRegexValidationError(pattern) == nil else { return nil }
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: pattern)
    }

    private static func title(_ title: String, matches regex: NSRegularExpression?) -> Bool {
        guard let regex else { return false }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return regex.firstMatch(in: title, range: range) != nil
    }

    static func normalizeTeamFilters(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for value in values {
            let cleaned = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
                .lowercased()
            guard !cleaned.isEmpty, !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)
            normalized.append(cleaned)
        }

        return normalized
    }
}
