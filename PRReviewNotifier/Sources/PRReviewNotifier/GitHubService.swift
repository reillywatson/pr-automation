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

    private func graphql(query: String, variables: [String: Any]) async throws -> Data {
        guard let url = URL(string: "https://api.github.com/graphql") else {
            throw GitHubError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": variables
        ])

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
        let query = "is:pr is:open review-requested:\(username) archived:false"
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let perPage = 100
        var page = 1
        var issues: [SearchIssue] = []
        var totalCount: Int?

        repeat {
            let data = try await request("/search/issues?q=\(encodedQuery)&per_page=\(perPage)&page=\(page)")
            let result = try decoder.decode(SearchResult.self, from: data)
            issues.append(contentsOf: result.items)
            totalCount = result.totalCount
            page += 1
        } while issues.count < (totalCount ?? 0) && page <= 10

        return issues
    }

    func getPullRequest(owner: String, repo: String, number: Int) async throws -> PullRequestDetails {
        let data = try await request("/repos/\(owner)/\(repo)/pulls/\(number)")
        return try decoder.decode(PullRequestDetails.self, from: data)
    }

    func getIssueEvents(owner: String, repo: String, number: Int) async throws -> [IssueEvent] {
        let data = try await request("/repos/\(owner)/\(repo)/issues/\(number)/events?per_page=100")
        return try decoder.decode([IssueEvent].self, from: data)
    }

    func getIssueComments(owner: String, repo: String, number: Int) async throws -> [IssueComment] {
        let data = try await request("/repos/\(owner)/\(repo)/issues/\(number)/comments?per_page=100")
        return try decoder.decode([IssueComment].self, from: data)
    }

    func getReviews(owner: String, repo: String, number: Int) async throws -> [Review] {
        let data = try await request("/repos/\(owner)/\(repo)/pulls/\(number)/reviews?per_page=100")
        return try decoder.decode([Review].self, from: data)
    }

    func getReviewThreads(owner: String, repo: String, number: Int) async throws -> [ReviewThread] {
        let query = """
        query($owner: String!, $repo: String!, $number: Int!) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              reviewThreads(first: 100) {
                nodes {
                  id
                  isResolved
                  isOutdated
                  comments(first: 100) {
                    nodes {
                      databaseId
                      body
                      createdAt
                      updatedAt
                      author { login }
                      pullRequestReview {
                        databaseId
                        author { login }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """
        let data = try await graphql(query: query, variables: [
            "owner": owner,
            "repo": repo,
            "number": number
        ])
        let response = try decoder.decode(ReviewThreadsResponse.self, from: data)
        return response.data.repository.pullRequest.reviewThreads.nodes
    }

    func getPullRequestSummaries(for issues: [SearchIssue]) async throws -> [PullRequestSummary] {
        var summaries: [PullRequestSummary] = []
        let batchSize = 10

        for start in stride(from: 0, to: issues.count, by: batchSize) {
            let batch = Array(issues[start..<min(start + batchSize, issues.count)])
            let query = try pullRequestSummaryQuery(for: batch)
            let data = try await graphql(query: query, variables: [:])
            let response = try decoder.decode(PullRequestSummaryBatchResponse.self, from: data)

            for index in batch.indices {
                guard let repository = response.data["pr\(index)"],
                      let pullRequest = repository?.pullRequest else {
                    continue
                }
                summaries.append(pullRequest.summary)
            }
        }

        return summaries
    }

    private func pullRequestSummaryQuery(for issues: [SearchIssue]) throws -> String {
        let fields = try issues.enumerated().compactMap { index, issue -> String? in
            let parts = issue.repoFullName.split(separator: "/")
            guard parts.count == 2 else { return nil }
            let owner = try graphqlStringLiteral(String(parts[0]))
            let repo = try graphqlStringLiteral(String(parts[1]))

            return """
              pr\(index): repository(owner: \(owner), name: \(repo)) {
                pullRequest(number: \(issue.number)) {
                  number
                  title
                  url
                  repository { nameWithOwner }
                  reviews(first: 100) {
                    nodes {
                      databaseId
                      state
                      body
                      author { login }
                    }
                  }
                  reviewThreads(first: 100) {
                    nodes {
                      id
                      isResolved
                      isOutdated
                      comments(first: 100) {
                        nodes {
                          databaseId
                          body
                          createdAt
                          updatedAt
                          author { login }
                          pullRequestReview {
                            databaseId
                            author { login }
                          }
                        }
                      }
                    }
                  }
                }
              }
            """
        }

        return """
        query {
        \(fields.joined(separator: "\n"))
        }
        """
    }

    private func graphqlStringLiteral(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

private struct ReviewThreadsResponse: Codable {
    let data: ReviewThreadsData
}

private struct ReviewThreadsData: Codable {
    let repository: ReviewThreadsRepository
}

private struct ReviewThreadsRepository: Codable {
    let pullRequest: ReviewThreadsPullRequest
}

private struct ReviewThreadsPullRequest: Codable {
    let reviewThreads: ReviewThreadsConnection
}

private struct ReviewThreadsConnection: Codable {
    let nodes: [ReviewThread]
}

private struct PullRequestSummaryBatchResponse: Codable {
    let data: [String: PullRequestSummaryRepository?]
}

private struct PullRequestSummaryRepository: Codable {
    let pullRequest: PullRequestSummaryNode?
}

private struct PullRequestSummaryNode: Codable {
    let number: Int
    let title: String
    let url: String
    let repository: PullRequestSummaryRepositoryInfo
    let reviews: PullRequestSummaryReviewsConnection
    let reviewThreads: ReviewThreadsConnection

    var summary: PullRequestSummary {
        return PullRequestSummary(
            number: number,
            title: title,
            repoFullName: repository.nameWithOwner,
            reviews: reviews.nodes.compactMap(\.review),
            reviewThreads: reviewThreads.nodes,
            htmlURL: url
        )
    }
}

private struct PullRequestSummaryRepositoryInfo: Codable {
    let nameWithOwner: String
}

private struct PullRequestSummaryReviewsConnection: Codable {
    let nodes: [PullRequestSummaryReview]
}

private struct PullRequestSummaryReview: Codable {
    let databaseId: Int?
    let state: String
    let body: String
    let author: LoginUser?

    var review: Review? {
        guard let databaseId else { return nil }
        return Review(
            id: databaseId,
            user: author.map { BotUser(login: $0.login, id: 0) },
            state: state,
            body: body,
            submittedAt: nil
        )
    }
}
