import Foundation
import LangGraph

enum OutcomeRating: Int, Codable, Equatable, Comparable {
    case failed = 0
    case partial = 1
    case success = 2

    static func < (lhs: OutcomeRating, rhs: OutcomeRating) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ExecutionTrace {
    let taskDescription: String
    let generatedGraph: GraphConfig
    let actualExecutionPath: [String]
    let executionTimes: [String: TimeInterval]
    let reflectionLoops: [(node: String, reason: String)]
    let userInterventions: [(step: String, correction: String)]
    let finalOutcome: OutcomeRating
    let timestamp: Date
}

final class ExecutionMemory: ExecutionHistoryStore {
    private(set) var traces: [ExecutionTrace] = []

    func findSimilar(to task: String, limit: Int) async throws -> [ExecutionRecord] {
        let scored = traces.map { trace in
            (trace, semanticSimilarity(trace.taskDescription, task))
        }.sorted { $0.1 > $1.1 }
        return scored.prefix(limit).map {
            ExecutionRecord(
                task: $0.0.taskDescription,
                summary: $0.0.actualExecutionPath.joined(separator: " -> "),
                outcome: "\($0.0.finalOutcome)",
                improvements: "Used graph with \($0.0.generatedGraph.nodes.count) nodes"
            )
        }
    }

    func record(_ trace: ExecutionTrace) {
        traces.append(trace)
    }

    private func semanticSimilarity(_ a: String, _ b: String) -> Double {
        let setA = Set(a.lowercased().split(separator: " ").map(String.init))
        let setB = Set(b.lowercased().split(separator: " ").map(String.init))
        let intersection = setA.intersection(setB).count
        let union = max(setA.union(setB).count, 1)
        return Double(intersection) / Double(union)
    }
}

final class GraphEvolver {
    private let llm: LLMClient
    private let nodeRegistry: NodeRegistry
    private let memory: ExecutionMemory

    init(llm: LLMClient, nodeRegistry: NodeRegistry, memory: ExecutionMemory) {
        self.llm = llm
        self.nodeRegistry = nodeRegistry
        self.memory = memory
    }

    func buildGraphForTask(_ task: String, context: [String: Any]) async throws -> GraphSynthesisResult {
        let base: GraphSynthesisResult
        do {
            base = try await GraphQueryBuilder(llm: llm, nodeRegistry: nodeRegistry).buildGraphForTask(task, context: context)
        } catch {
            base = GraphSynthesisResult(
                config: minimalGraph(),
                reasoning: "Fallback graph because synthesis failed: \(error)",
                estimatedCost: EstimatedCost(timeSeconds: nil, apiCalls: nil, confidence: nil)
            )
        }
        let similar = try await memory.findSimilar(to: task, limit: 1)
        guard let first = similar.first else {
            return base
        }

        let prompt = """
        Task: \(task)
        Initial graph: \(base.config)

        Similar past execution:
        Task: \(first.task)
        Outcome: \(first.outcome)
        Summary: \(first.summary)
        Improvements: \(first.improvements)

        Modify the initial graph to avoid past mistakes:
        - Remove nodes that weren't needed
        - Add missing nodes
        - Reorder to satisfy dependencies seen in execution
        - Add reflection after nodes that needed user intervention

        Return JSON with a graph matching the GraphConfig schema (nodes, edges, reflection_points, entry_node).
        """
        let response = try await llm.complete(prompt: prompt)
        do {
            return try GraphQueryBuilder(llm: llm, nodeRegistry: nodeRegistry).parseGraphConfig(response)
        } catch {
            return base
        }
    }

    func recordExecution(trace: ExecutionTrace) {
        memory.record(trace)
    }

    private func minimalGraph() -> GraphConfig {
        let nodes = nodeRegistry.catalog().compactMap { try? nodeRegistry.resolve($0.id) }
        guard let first = nodes.first else {
            return GraphConfig(nodes: [], edges: [], reflectionPoints: [:], entryNode: START)
        }
        var edges: [Edge] = [.linear(from: START, to: first.id)]
        var prev = first.id
        for node in nodes.dropFirst() {
            edges.append(.linear(from: prev, to: node.id))
            prev = node.id
        }
        edges.append(.linear(from: prev, to: END))
        return GraphConfig(nodes: nodes, edges: edges, reflectionPoints: [:], entryNode: first.id)
    }
}
