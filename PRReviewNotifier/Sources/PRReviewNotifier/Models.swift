import Foundation

struct GitHubUser: Codable {
    let login: String
    let id: Int
}

struct SearchResult: Codable {
    let items: [SearchIssue]
    let totalCount: Int

    enum CodingKeys: String, CodingKey {
        case items
        case totalCount = "total_count"
    }
}

struct SearchIssue: Codable {
    let number: Int
    let title: String
    let htmlURL: String
    let repositoryURL: String

    enum CodingKeys: String, CodingKey {
        case number, title
        case htmlURL = "html_url"
        case repositoryURL = "repository_url"
    }

    var repoFullName: String {
        repositoryURL.components(separatedBy: "/repos/").last ?? repositoryURL
    }
}

struct Review: Codable {
    let id: Int
    let user: BotUser?
    let state: String
    let body: String
    let submittedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case user
        case state
        case body
        case submittedAt = "submitted_at"
    }

    var isFromAIBot: Bool {
        guard let login = user?.login.lowercased() else { return false }
        return login.contains("copilot") || login.contains("codex") || login.contains("openai")
    }
}

struct BotUser: Codable {
    let login: String
    let id: Int
}

struct LoginUser: Codable {
    let login: String
}

struct PullRequestDetails: Codable {
    let requestedReviewers: [BotUser]
    let requestedTeams: [RequestedTeam]

    enum CodingKeys: String, CodingKey {
        case requestedReviewers = "requested_reviewers"
        case requestedTeams = "requested_teams"
    }
}

struct RequestedTeam: Codable {
    let name: String
    let slug: String
}

struct IssueEvent: Codable {
    let id: Int
    let event: String
    let createdAt: String?
    let requestedReviewer: BotUser?
    let requestedTeam: RequestedTeam?

    enum CodingKeys: String, CodingKey {
        case id, event
        case createdAt = "created_at"
        case requestedReviewer = "requested_reviewer"
        case requestedTeam = "requested_team"
    }
}

struct IssueComment: Codable {
    let id: Int
    let body: String
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, body
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ReviewThread: Codable {
    let id: String
    let isResolved: Bool
    let isOutdated: Bool
    let comments: ReviewThreadComments
}

struct ReviewThreadComments: Codable {
    let nodes: [ReviewThreadComment]
}

struct ReviewThreadComment: Codable {
    let databaseId: Int?
    let body: String
    let author: LoginUser?
    let createdAt: String?
    let updatedAt: String?
    let pullRequestReview: ReviewThreadReview?

    enum CodingKeys: String, CodingKey {
        case databaseId
        case body
        case author
        case createdAt
        case updatedAt
        case pullRequestReview
    }
}

struct ReviewThreadReview: Codable {
    let databaseId: Int?
    let author: LoginUser?
}

struct PullRequestSummary {
    let number: Int
    let title: String
    let repoFullName: String
    let reviews: [Review]
    let reviewThreads: [ReviewThread]
    let htmlURL: String

    var id: String {
        "\(repoFullName)#\(number)"
    }
}

struct ReadyPR: Identifiable, Equatable {
    let id: String
    let title: String
    let repoName: String
    let reviewRequestReason: String
    let reviewRequestedAt: Date?
    let activityFingerprint: String
    let snoozedUntil: Date?
    let url: String

    static func == (lhs: ReadyPR, rhs: ReadyPR) -> Bool { lhs.id == rhs.id }

    func snoozed(until date: Date) -> ReadyPR {
        ReadyPR(
            id: id,
            title: title,
            repoName: repoName,
            reviewRequestReason: reviewRequestReason,
            reviewRequestedAt: reviewRequestedAt,
            activityFingerprint: activityFingerprint,
            snoozedUntil: date,
            url: url
        )
    }

    func unsnoozed() -> ReadyPR {
        ReadyPR(
            id: id,
            title: title,
            repoName: repoName,
            reviewRequestReason: reviewRequestReason,
            reviewRequestedAt: reviewRequestedAt,
            activityFingerprint: activityFingerprint,
            snoozedUntil: nil,
            url: url
        )
    }
}
