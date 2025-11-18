import Foundation

enum EscalationStrategy {
    case escalateAfterMax
    case immediateEscalation
    case askUser(String)
}

enum ReflectionResult {
    case success
    case refine(targetNode: String, reason: String)
    case escalate(reason: String)
    case requestUserInput(question: String)
}

struct ReflectionCriteria {
    let evaluate: (LifeState) -> ReflectionResult
    let maxRetries: Int
    let escalationStrategy: EscalationStrategy

    init(
        maxRetries: Int = 3,
        escalationStrategy: EscalationStrategy = .escalateAfterMax,
        evaluate: @escaping (LifeState) -> ReflectionResult
    ) {
        self.evaluate = evaluate
        self.maxRetries = maxRetries
        self.escalationStrategy = escalationStrategy
    }
}

enum ReflectionLevel: String {
    case strategic
    case tactical
    case execution
}

struct ReflectionAction {
    let result: ReflectionResult
    let level: ReflectionLevel
}

struct HierarchicalReflector {
    let levels: [ReflectionLevel: ReflectionCriteria]

    func reflect(state: LifeState) async -> ReflectionAction {
        let ordered: [ReflectionLevel] = [.strategic, .tactical, .execution]
        for level in ordered {
            guard let criteria = levels[level] else { continue }
            let result = criteria.evaluate(state)
            if case .success = result {
                continue
            }
            return ReflectionAction(result: result, level: level)
        }
        return ReflectionAction(result: .success, level: .execution)
    }
}

protocol EvaluationGenerator {
    func generateCriteria(task: String, context: [String: Any]) async throws -> ReflectionCriteria
}

final class LLMEvaluationGenerator: EvaluationGenerator {
    private let llm: LLMClient

    init(llm: LLMClient) {
        self.llm = llm
    }

    func generateCriteria(task: String, context: [String: Any]) async throws -> ReflectionCriteria {
        let prompt = """
        Task: \(task)

        Generate 3-5 concrete, programmatically-checkable success conditions.
        Generate 3-5 failure patterns that indicate strategy change needed.

        Format:
        SUCCESS: <condition>
        REFINE: <condition> -> retry <node>
        ESCALATE: <condition> -> user input needed
        """
        _ = try await llm.complete(prompt: prompt)

        return ReflectionCriteria { state in
            if state[actionPlanSummaryKey]?.isEmpty ?? true {
                return .refine(targetNode: "generate_life_audit", reason: "Missing action summary")
            }
            if (state[prioritizedTasksKey]?.isEmpty ?? true) && (state[tripPlanKey] == nil) {
                return .requestUserInput(question: "No tasks found; should we broaden the search?")
            }
            return .success
        }
    }
}
