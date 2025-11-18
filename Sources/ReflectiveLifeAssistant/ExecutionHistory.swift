import Foundation

struct ExecutionRecord: Equatable {
    let task: String
    let summary: String
    let outcome: String
    let improvements: String
}

protocol ExecutionHistoryStore {
    func findSimilar(to task: String, limit: Int) async throws -> [ExecutionRecord]
}

struct InMemoryExecutionHistoryStore: ExecutionHistoryStore {
    var records: [ExecutionRecord]

    func findSimilar(to task: String, limit: Int) async throws -> [ExecutionRecord] {
        return Array(records.prefix(limit))
    }
}
