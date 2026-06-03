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

    var isFromAIBot: Bool {
        guard let login = user?.login.lowercased() else { return false }
        return login.contains("copilot") || login.contains("codex") || login.contains("openai")
    }
}

struct BotUser: Codable {
    let login: String
    let id: Int
}

struct ReviewComment: Codable {
    let id: Int
    let user: BotUser?
    let body: String
    let position: Int?
    let inReplyToId: Int?
    let pullRequestReviewId: Int?

    enum CodingKeys: String, CodingKey {
        case id, user, body, position
        case inReplyToId = "in_reply_to_id"
        case pullRequestReviewId = "pull_request_review_id"
    }

    var isOutdated: Bool { position == nil }
}

struct ReadyPR: Identifiable, Equatable {
    let id: Int
    let title: String
    let repoName: String
    let url: String

    static func == (lhs: ReadyPR, rhs: ReadyPR) -> Bool { lhs.id == rhs.id }
}
