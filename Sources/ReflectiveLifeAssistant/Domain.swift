import Foundation

final class ExecutionContext {
    let llm: LLMClient
    let messageStore: MessageStore
    let fileSystem: FileSystemClient
    let calendar: CalendarClient
    let finance: FinanceClient
    let evaluationGenerator: EvaluationGenerator?
    var pendingMutations: [GraphMutation] = []

    init(
        llm: LLMClient,
        messageStore: MessageStore,
        fileSystem: FileSystemClient,
        calendar: CalendarClient,
        finance: FinanceClient,
        evaluationGenerator: EvaluationGenerator?
    ) {
        self.llm = llm
        self.messageStore = messageStore
        self.fileSystem = fileSystem
        self.calendar = calendar
        self.finance = finance
        self.evaluationGenerator = evaluationGenerator
    }

    func requestMutation(_ mutation: GraphMutation) {
        pendingMutations.append(mutation)
    }
}

protocol DomainNode {
    var id: String { get }
    var inputRequirements: [AnyStateKey] { get }
    var outputKeys: [AnyStateKey] { get }
    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any]
}
