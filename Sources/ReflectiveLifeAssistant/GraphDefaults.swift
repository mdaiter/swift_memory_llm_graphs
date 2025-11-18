import Foundation
import LangGraph

// MARK: - Reflection criteria builders

func makeTripReflectionCriteria() -> ReflectionCriteria {
    ReflectionCriteria { state in
        guard let plan = state[tripPlanKey]?.summary.lowercased() else {
            return .refine(targetNode: "plan_trip", reason: "Missing trip plan")
        }
        if !plan.contains("mexico") || !plan.contains("30") {
            return .refine(targetNode: "plan_trip", reason: "Trip summary lacks Mexico + 30th birthday context")
        }
        return .success
    }
}

func makeEmailReflectionCriteria() -> ReflectionCriteria {
    ReflectionCriteria { state in
        let replies = state[draftedRepliesKey] ?? []
        if replies.isEmpty {
            return .refine(targetNode: "draft_email", reason: "No drafted replies yet")
        }
        if replies.contains(where: { $0.count < 30 }) {
            return .refine(targetNode: "draft_email", reason: "Reply too short")
        }
        return .success
    }
}

func makeHierarchicalReflector() -> HierarchicalReflector {
    let strategic = ReflectionCriteria(maxRetries: 2) { state in
        if state[userRequestKey]?.isEmpty ?? true {
            return .requestUserInput(question: "What do you want to accomplish?")
        }
        return .success
    }

    let tactical = ReflectionCriteria(maxRetries: 2) { state in
        if state[tripPlanKey] == nil {
            return .refine(targetNode: "plan_trip", reason: "Trip plan missing")
        }
        if state[draftedRepliesKey]?.isEmpty ?? true {
            return .refine(targetNode: "draft_email", reason: "Email drafts missing")
        }
        return .success
    }

    let execution = ReflectionCriteria(maxRetries: 3) { state in
        if let plan = state[tripPlanKey]?.summary.lowercased(),
           !(plan.contains("mexico") && plan.contains("30")) {
            return .refine(targetNode: "plan_trip", reason: "Trip is off target")
        }
        if (state[draftedRepliesKey] ?? []).contains(where: { $0.count < 30 }) {
            return .refine(targetNode: "draft_email", reason: "Reply too short for user tone")
        }
        return .success
    }

    return HierarchicalReflector(levels: [
        .strategic: strategic,
        .tactical: tactical,
        .execution: execution
    ])
}

// MARK: - Node registration helpers

func makeNodes(now: Date) -> [DomainNode] {
    let reflector = makeHierarchicalReflector()
    return [
        LoadMessagesNode(),
        InferStyleNode(),
        ScanFilesNode(),
        ScanCalendarNode(now: now),
        ScanFinancesNode(),
        ExtractTasksNode(),
        PrioritizeTasksNode(),
        TripPlanningNode(),
        EmailDraftingNode(),
        JobOfferAnalysisNode(),
        ReflectionNode(reflector: reflector, defaultNext: "generate_life_audit"),
        GenerateActionPlanNode(),
        GenerateLifeAuditNode()
    ]
}

func registerNodes(_ registry: NodeRegistry, nodes: [DomainNode]) {
    for node in nodes {
        // Rough heuristics for cost/latency metadata to inform graph synthesis prompt.
        let metadata: (Double?, Int?)
        switch node.id {
        case "load_messages", "scan_files", "scan_calendar", "scan_finances":
            metadata = (0.1, 150)
        case "infer_style":
            metadata = (0.2, 300)
        case "plan_trip", "draft_email", "generate_action_plan", "generate_life_audit", "job_offer_analysis":
            metadata = (0.5, 600)
        case "reflect":
            metadata = (0.05, 100)
        default:
            metadata = (nil, nil)
        }
        registry.register(node, cost: metadata.0, latencyMs: metadata.1)
    }
}

// MARK: - Fallback graph (for when LLM synthesis fails)

func fallbackGraphConfig(now: Date) -> GraphConfig {
    let nodes = makeNodes(now: now)
    let edges: [Edge] = [
        .linear(from: START, to: "load_messages"),
        .linear(from: "load_messages", to: "infer_style"),
        .linear(from: "infer_style", to: "scan_files"),
        .linear(from: "scan_files", to: "scan_calendar"),
        .linear(from: "scan_calendar", to: "scan_finances"),
        .linear(from: "scan_finances", to: "extract_tasks"),
        .linear(from: "extract_tasks", to: "prioritize_tasks"),
        .linear(from: "prioritize_tasks", to: "plan_trip"),
        .linear(from: "plan_trip", to: "draft_email"),
        .linear(from: "draft_email", to: "job_offer_analysis"),
        .linear(from: "job_offer_analysis", to: "reflect"),
        .keyed(
            from: "reflect",
            key: nextNodeKey,
            mapping: [
                "plan_trip": "plan_trip",
                "draft_email": "draft_email",
                "generate_life_audit": "generate_life_audit",
                "job_offer_analysis": "job_offer_analysis"
            ],
            fallback: "generate_life_audit"
        ),
        .linear(from: "generate_life_audit", to: END)
    ]

    let reflectionPoints: [String: ReflectionCriteria] = [
        "plan_trip": makeTripReflectionCriteria(),
        "draft_email": makeEmailReflectionCriteria()
    ]

    return GraphConfig(
        nodes: nodes,
        edges: edges,
        reflectionPoints: reflectionPoints,
        entryNode: "load_messages"
    )
}
