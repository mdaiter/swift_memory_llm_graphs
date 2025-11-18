import Foundation

enum GraphQueryBuilderError: Error {
    case invalidJSON
    case missingNode(String)
    case missingEntryNode
}

struct EstimatedCost: Equatable {
    let timeSeconds: Double?
    let apiCalls: Int?
    let confidence: Double?
}

struct GraphSynthesisResult {
    let config: GraphConfig
    let reasoning: String
    let estimatedCost: EstimatedCost
}

struct GraphQueryBuilder {
    let llm: LLMClient
    let nodeRegistry: NodeRegistry

    func buildGraphForTask(_ userTask: String, context: [String: Any] = [:]) async throws -> GraphSynthesisResult {
        let prompt = makeGraphGenerationPrompt(task: userTask, context: context)
        let response = try await llm.complete(prompt: prompt)
        return try parseGraphConfig(response)
    }

    func selectTemplate(for task: String) async throws -> GraphTemplate {
        let prompt = """
        Classify this task into a graph template:

        Task: \(task)

        Templates:
        - simpleQuery: Single straightforward action (e.g., "What's on my calendar today?")
        - dataAggregation: Needs to gather info from multiple sources (e.g., "Summarize my finances")
        - iterativeRefinement: Creative task that needs refinement (e.g., "Write a blog post")
        - decisionSupport: Complex decision with tradeoffs (e.g., "Should I buy this house?")
        - multiStepWorkflow: Multiple sequential tasks (e.g., "Book trip then notify team")

        Output JSON: {"template": "...", "confidence": 0.9, "reasoning": "..."}
        """
        let response = try await llm.complete(prompt: prompt)
        guard
            let data = response.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let templateValue = json["template"] as? String
        else {
            throw GraphQueryBuilderError.invalidJSON
        }
        return GraphTemplate(rawValue: templateValue) ?? .decisionSupport
    }

    func makeGraphGenerationPrompt(task: String, context: [String: Any]) -> String {
        let availableNodes = nodeRegistry.catalog()
        return """
        You are a graph planner for an LLM agent system. Given a user task, you must construct
        an optimal execution graph using available nodes.

        AVAILABLE NODES:
        \(formatNodeCatalog(availableNodes))

        USER TASK:
        \(task)

        CONTEXT:
        \(formatContext(context))

        GRAPH CONSTRUCTION RULES:

        1. DEPENDENCY ANALYSIS
           - Identify what information the task needs
           - Determine which nodes provide that information
           - Order nodes so dependencies are satisfied before consumers

        2. PARALLELIZATION OPPORTUNITIES
           - Nodes with no shared dependencies can run in parallel
           - Use .parallel() edges for independent branches

        3. REFLECTION PLACEMENT
           - Add reflection after nodes that produce user-facing output
           - Add reflection after nodes with high uncertainty
           - Add reflection before irreversible actions (sending emails, making purchases)

        4. CONDITIONAL ROUTING
           - Use .conditional() when execution path depends on intermediate results
           - Use .keyed() when reflection determines next node

        5. OPTIMIZATION
           - Minimize total nodes (avoid redundant work)
           - Maximize parallelism (reduce wall-clock time)
           - Front-load cheap validation nodes (fail fast)

        OUTPUT FORMAT (JSON):
        {
          "reasoning": {
            "task_decomposition": "...",
            "required_information": ["..."],
            "selected_nodes": [{"node_id": "scan_calendar", "reason": "Need to check scheduling conflicts"}],
            "execution_strategy": "parallel vs sequential, with justification",
            "reflection_points": [{"after_node": "draft_email", "reason": "User-facing output that needs validation"}],
            "uncertainty_points": ["Where ambiguity exists in the task"]
          },
          "graph": {
            "nodes": ["node_id_1", "node_id_2", ...],
            "edges": [
              {"type": "linear", "from": "START", "to": "node_1"},
              {"type": "parallel", "from": "node_1", "to": ["node_2", "node_3"]},
              {"type": "conditional", "from": "node_4", "key": "decision_key", "branches": {...}},
              {"type": "linear", "from": "node_5", "to": "END"}
            ],
            "reflection_points": {
              "node_id": {
                "criteria": "What to check",
                "max_retries": 3,
                "fallback_node": "alternative_node_id"
              }
            },
            "entry_node": "first_node_id"
          },
          "estimated_complexity": {
            "node_count": 5,
            "parallel_branches": 2,
            "reflection_points": 1,
            "expected_iterations": "1-2"
          },
          "estimated_cost": { "time_seconds": 12.5, "api_calls": 4, "confidence": 0.72 }
        }

        OPTIMIZATION CRITERIA (in order):
        1. Correctness: Graph must satisfy task requirements
        2. Minimality: Fewest nodes that solve the task
        3. Latency: Maximize parallelism, minimize sequential depth
        4. Robustness: Add reflection at high-uncertainty points
        5. Cost: Prefer cheaper nodes when alternatives exist

        REASONING PROCESS:
        Step 1: Task decomposition (what is asked? what info is needed? what actions?)
        Step 2: Node selection (which nodes supply that info / take those actions? remove redundant nodes)
        Step 3: Dependency ordering (DAG, parallelize independent branches)
        Step 4: Uncertainty analysis (user-facing or high-variance nodes → add reflection)
        Step 5: Failure modes (where can this fail? add fallbacks / user confirmation)
        """
    }

    func parseGraphConfig(_ response: String) throws -> GraphSynthesisResult {
        guard let data = response.data(using: .utf8) else { throw GraphQueryBuilderError.invalidJSON }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let graphJson = json["graph"] as? [String: Any],
              let nodeIds = graphJson["nodes"] as? [String]
        else { throw GraphQueryBuilderError.invalidJSON }

        let nodes = try nodeIds.map { try nodeRegistry.resolve($0) }
        let requestedEntry = graphJson["entry_node"] as? String
        let entryNode = nodeIds.contains(where: { $0 == requestedEntry }) ? (requestedEntry ?? nodeIds.first) : nodeIds.first
        guard let entryNode else { throw GraphQueryBuilderError.missingEntryNode }

        var parsedEdges: [Edge] = []
        if let edgeItems = graphJson["edges"] as? [[String: Any]] {
            for item in edgeItems {
                guard let type = item["type"] as? String else { continue }
                switch type {
                case "linear":
                    if let from = item["from"] as? String, let to = item["to"] as? String {
                        parsedEdges.append(.linear(from: from, to: to))
                    }
                case "parallel":
                    if let from = item["from"] as? String, let tos = item["to"] as? [String] {
                        parsedEdges.append(.parallel(from: from, tos: tos))
                    }
                case "conditional", "keyed":
                    if let from = item["from"] as? String,
                       let key = item["key"] as? String,
                       let branches = item["branches"] as? [String: String] {
                        let fallback = item["fallback"] as? String ?? branches.values.first ?? entryNode
                        parsedEdges.append(.keyedDynamic(from: from, keyName: key, mapping: branches, fallback: fallback))
                    }
                default:
                    continue
                }
            }
        }

        var reflectionPoints: [String: ReflectionCriteria] = [:]
        if let reflectionJson = graphJson["reflection_points"] as? [String: [String: Any]] {
            for (nodeId, details) in reflectionJson {
                let maxRetries = details["max_retries"] as? Int ?? 3
                let fallback = details["fallback_node"] as? String ?? entryNode
                let criteriaText = details["criteria"] as? String ?? "validate output"
                let criteria = ReflectionCriteria(maxRetries: maxRetries) { state in
                    if state[actionPlanSummaryKey]?.isEmpty ?? true {
                        return .refine(targetNode: fallback, reason: criteriaText)
                    }
                    return .success
                }
                reflectionPoints[nodeId] = criteria
            }
        }

        let reasoning: String
        if let reasonStr = json["reasoning"] as? String {
            reasoning = reasonStr
        } else if let reasonDict = json["reasoning"] as? [String: Any] {
            reasoning = reasonDict.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        } else {
            reasoning = ""
        }

        let costJson = json["estimated_cost"] as? [String: Any] ?? [:]
        func asDouble(_ any: Any?) -> Double? {
            if let d = any as? Double { return d }
            if let i = any as? Int { return Double(i) }
            return nil
        }
        let estimated = EstimatedCost(
            timeSeconds: asDouble(costJson["time_seconds"]),
            apiCalls: costJson["api_calls"] as? Int,
            confidence: asDouble(costJson["confidence"])
        )

        return GraphSynthesisResult(
            config: GraphConfig(nodes: nodes, edges: parsedEdges, reflectionPoints: reflectionPoints, entryNode: entryNode),
            reasoning: reasoning,
            estimatedCost: estimated
        )
    }
}

// MARK: - Formatting helpers

func formatNodeCatalog(_ nodes: [NodeDescriptor]) -> String {
    guard !nodes.isEmpty else { return "- none -" }
    return nodes
        .map { descriptor in
            let cost = descriptor.cost.map { String(format: "%.2f", $0) } ?? "n/a"
            let latency = descriptor.latencyMs.map { "\($0)ms" } ?? "n/a"
            return "- \(descriptor.id)\n  inputs: \(descriptor.inputs)\n  outputs: \(descriptor.outputs)\n  cost: \(cost)\n  latency: \(latency)"
        }
        .joined(separator: "\n")
}

func formatContext(_ context: [String: Any]) -> String {
    guard !context.isEmpty else { return "None" }
    return context.map { key, value in "\(key): \(value)" }.joined(separator: "\n")
}

func formatExecutionHistory(_ records: [ExecutionRecord]) -> String {
    guard !records.isEmpty else { return "None" }
    return records.map { record in
        "- Task: \"\(record.task)\"\n  Outcome: \(record.outcome)\n  Summary: \(record.summary)\n  Improvement: \(record.improvements)"
    }.joined(separator: "\n")
}

enum GraphTemplate: String {
    case simpleQuery
    case dataAggregation
    case iterativeRefinement
    case decisionSupport
    case multiStepWorkflow
}

struct LearningGraphBuilder {
    let llm: LLMClient
    let nodeRegistry: NodeRegistry
    let executionHistory: ExecutionHistoryStore

    func buildGraphForTask(_ task: String) async throws -> GraphSynthesisResult {
        let history = try await executionHistory.findSimilar(to: task, limit: 3)
        let prompt = """
        TASK: \(task)

        SIMILAR PAST EXECUTIONS:
        \(formatExecutionHistory(history))

        LEARNINGS FROM PAST EXECUTIONS:
        - Identify failure points and add missing preconditions before generation.
        - Add style/validation nodes before any user-facing output if past runs retried for tone/accuracy.
        - Prefer parallel fetch of independent data (calendar, files, finance) when past runs were slow.

        Use these learnings to construct a better initial graph.
        Avoid patterns that failed. Adopt patterns that succeeded.

        \(GraphQueryBuilder(llm: llm, nodeRegistry: nodeRegistry).makeGraphGenerationPrompt(task: task, context: [:]))
        """
        let response = try await llm.complete(prompt: prompt)
        return try GraphQueryBuilder(llm: llm, nodeRegistry: nodeRegistry).parseGraphConfig(response)
    }
}
