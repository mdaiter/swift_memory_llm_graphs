import Foundation

struct ExecutionContext {
    let llm: LLMClient
    let messageStore: MessageStore
    let fileSystem: FileSystemClient
    let calendar: CalendarClient
    let finance: FinanceClient
    let evaluationGenerator: EvaluationGenerator?
}

protocol DomainNode {
    var id: String { get }
    var inputRequirements: [AnyStateKey] { get }
    var outputKeys: [AnyStateKey] { get }
    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any]
}
