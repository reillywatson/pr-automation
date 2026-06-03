import Foundation

enum GitHubError: Error, LocalizedError {
    case invalidURL
    case noToken
    case httpError(Int, String)
    case rateLimited(retryAfter: Int?)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .noToken: return "No GitHub token configured"
        case .httpError(let code, let msg): return "GitHub API error \(code): \(msg)"
        case .rateLimited(let after):
            if let after { return "Rate limited — retry in \(after)s" }
            return "Rate limited by GitHub API"
        }
    }
}

class GitHubService {
    private let token: String
    private let session: URLSession
    private let decoder: JSONDecoder

    init(token: String) {
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
    }

    private func request(_ path: String) async throws -> Data {
        guard let url = URL(string: "https://api.github.com\(path)") else {
            throw GitHubError.invalidURL
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidURL }

        switch http.statusCode {
        case 200...299:
            return data
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw GitHubError.rateLimited(retryAfter: retryAfter)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError.httpError(http.statusCode, body)
        }
    }

    func getCurrentUser() async throws -> GitHubUser {
        let data = try await request("/user")
        return try decoder.decode(GitHubUser.self, from: data)
    }

    func getPRsRequestingReview(username: String) async throws -> [SearchIssue] {
        // GitHub search syntax: review-requested matches the current review request state
        let q = "is:pr+is:open+review-requested:\(username)+archived:false"
        let data = try await request("/search/issues?q=\(q)&per_page=50")
        return try decoder.decode(SearchResult.self, from: data).items
    }

    func getReviews(owner: String, repo: String, number: Int) async throws -> [Review] {
        let data = try await request("/repos/\(owner)/\(repo)/pulls/\(number)/reviews?per_page=100")
        return try decoder.decode([Review].self, from: data)
    }

    func getReviewComments(owner: String, repo: String, number: Int) async throws -> [ReviewComment] {
        let data = try await request("/repos/\(owner)/\(repo)/pulls/\(number)/comments?per_page=100")
        return try decoder.decode([ReviewComment].self, from: data)
    }
}
