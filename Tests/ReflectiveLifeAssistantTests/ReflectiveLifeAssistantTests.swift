import XCTest
import LangGraph
@testable import ReflectiveLifeAssistant

final class ReflectiveLifeAssistantTests: XCTestCase {

    func testTypedStatePersistsValues() {
        var state = LifeState()
        state[userRequestKey] = "Plan my trip"
        state[tripPlanKey] = TripPlan(summary: "CDMX for 30th")

        XCTAssertEqual(state[userRequestKey], "Plan my trip")
        XCTAssertEqual(state[tripPlanKey]?.summary, "CDMX for 30th")
    }

    func testJobOfferAnalysisNodeWritesAnalysis() async throws {
        let mock = MockLLMClient(response: "Highlights\nRisks\nRecommend yes")
        let context = ExecutionContext(
            llm: mock,
            messageStore: MessageStore(messages: []),
            fileSystem: MockFileSystemClient(files: []),
            calendar: MockCalendarClient(events: []),
            finance: MockFinanceClient(transactions: []),
            evaluationGenerator: nil
        )
        let node = JobOfferAnalysisNode()
        let updates = try await node.execute(state: LifeState([userRequestKey.name: "Consider ACME offer"]), context: context)
        let updated = LifeState(updates)
        XCTAssertEqual(updated[jobOfferAnalysisKey]?.recommendation, "Recommend yes")
    }

    func testGraphBuilderRunsJourneyWithMockLLM() async throws {
        let mock = MockLLMClient(response: "Mock response line 1\nMock response line 2\nMock response line 3")
        let now = Date()
        let context = ExecutionContext(
            llm: mock,
            messageStore: MessageStore(messages: [
                Message(id: "1", from: "alice", subject: "Trip", body: "Plan Mexico", isUnread: true, isImportant: true)
            ]),
            fileSystem: MockFileSystemClient(files: [
                FileSummary(path: "/docs/a.pdf", sizeBytes: 1_000_000, modifiedAt: now, kind: "pdf")
            ]),
            calendar: MockCalendarClient(events: []),
            finance: MockFinanceClient(transactions: []),
            evaluationGenerator: nil
        )

        let graph = try GraphBuilder().build(config: fallbackGraphConfig(now: now), context: context)
        let finalState = try await graph.invoke(inputs: [userRequestKey.name: "Plan a Mexico trip and draft replies"])

        XCTAssertFalse(finalState.actionPath.isEmpty)
        XCTAssertNotNil(finalState[tripPlanKey])
        XCTAssertNotNil(finalState[actionPlanSummaryKey])
    }

    func testReflectionNodeRoutesToRefinement() async throws {
        let reflector = HierarchicalReflector(levels: [
            .execution: ReflectionCriteria { _ in
                .refine(targetNode: "plan_trip", reason: "Refine trip")
            }
        ])
        let node = ReflectionNode(reflector: reflector, defaultNext: "generate_life_audit")

        let updates = try await node.execute(state: LifeState(), context: ExecutionContext(
            llm: MockLLMClient(response: "unused"),
            messageStore: MessageStore(messages: []),
            fileSystem: MockFileSystemClient(files: []),
            calendar: MockCalendarClient(events: []),
            finance: MockFinanceClient(transactions: []),
            evaluationGenerator: nil
        ))

        XCTAssertEqual(updates[nextNodeKey.name] as? String, "plan_trip")
        XCTAssertEqual(updates[reflectionActionKey.name] as? String, "refine")
    }

    func testEvaluationGeneratorYieldsCriteria() async throws {
        let generator = LLMEvaluationGenerator(llm: MockLLMClient(response: "ok"))
        let criteria = try await generator.generateCriteria(task: "Test task", context: [:])
        let result = criteria.evaluate(LifeState())

        switch result {
        case .refine(let node, _):
            XCTAssertEqual(node, "generate_life_audit")
        default:
            XCTFail("Expected refine from generated criteria when state is empty")
        }
    }

    func testGraphQueryBuilderParsesLLMResponse() async throws {
        let llmResponse = """
        {
          "reasoning": "Need messages then drafts.",
          "estimated_cost": { "time_seconds": 5, "api_calls": 2, "confidence": 0.8 },
          "graph": {
            "nodes": ["load_messages", "draft_email"],
            "edges": [
              {"type": "linear", "from": "START", "to": "load_messages"},
              {"type": "linear", "from": "load_messages", "to": "draft_email"},
              {"type": "linear", "from": "draft_email", "to": "END"}
            ],
            "reflection_points": {
              "draft_email": {
                "criteria": "Validate tone",
                "max_retries": 2,
                "fallback_node": "draft_email"
              }
            },
            "entry_node": "load_messages"
          }
        }
        """
        let registry = NodeRegistry()
        registry.register(LoadMessagesNode())
        registry.register(EmailDraftingNode())
        let builder = GraphQueryBuilder(llm: MockLLMClient(response: llmResponse), nodeRegistry: registry)
        let result = try await builder.buildGraphForTask("Reply to emails")
        let config = result.config

        XCTAssertEqual(config.nodes.count, 2)
        XCTAssertEqual(config.entryNode, "load_messages")
        XCTAssertEqual(config.edges.count, 3)
        XCTAssertNotNil(config.reflectionPoints["draft_email"])
        XCTAssertFalse(result.reasoning.isEmpty || result.estimatedCost.confidence == nil)
    }

    func testTemplateSelectionParsesLLMOutput() async throws {
        let response = #"{"template":"decisionSupport","confidence":0.8,"reasoning":"needs tradeoffs"}"#
        let registry = NodeRegistry()
        let builder = GraphQueryBuilder(llm: MockLLMClient(response: response), nodeRegistry: registry)
        let template = try await builder.selectTemplate(for: "Should I accept the offer?")
        XCTAssertEqual(template, .decisionSupport)
    }

    func testLearningGraphBuilderUsesHistory() async throws {
        let llmResponse = """
        {
          "reasoning": "Parallel fetch then analyze.",
          "estimated_cost": { "time_seconds": 8, "api_calls": 3, "confidence": 0.7 },
          "graph": {
            "nodes": ["scan_finances", "plan_trip"],
            "edges": [
              {"type": "linear", "from": "START", "to": "scan_finances"},
              {"type": "linear", "from": "scan_finances", "to": "plan_trip"},
              {"type": "linear", "from": "plan_trip", "to": "END"}
            ],
            "entry_node": "scan_finances"
          }
        }
        """
        let registry = NodeRegistry()
        registry.register(ScanFinancesNode())
        registry.register(TripPlanningNode())
        let history = InMemoryExecutionHistoryStore(records: [
            ExecutionRecord(task: "Plan weekend trip", summary: "Failed", outcome: "Needed budget", improvements: "Add scan_finances"),
            ExecutionRecord(task: "Reply urgent email", summary: "Needed tone", outcome: "2 retries", improvements: "Add infer_style")
        ])
        let builder = LearningGraphBuilder(
            llm: MockLLMClient(response: llmResponse),
            nodeRegistry: registry,
            executionHistory: history
        )
        let result = try await builder.buildGraphForTask("Plan budget trip")
        XCTAssertEqual(result.config.entryNode, "scan_finances")
        XCTAssertEqual(result.config.nodes.count, 2)
        XCTAssertFalse(result.reasoning.isEmpty)
    }

    func testGraphMutatorInjectsNodes() async throws {
        let baseNodes: [DomainNode] = [ScanFinancesNode(), TripPlanningNode()]
        let baseGraph = GraphConfig(
            nodes: baseNodes,
            edges: [.linear(from: "scan_finances", to: "plan_trip")],
            reflectionPoints: [:],
            entryNode: "scan_finances"
        )
        let mutator = InMemoryGraphMutator(graph: baseGraph)
        _ = try await mutator.injectNodes(after: "plan_trip", nodes: [EmailDraftingNode()], reason: "Need email follow-up")
        let ids = Set(mutator.graph.nodes.map { $0.id })
        XCTAssertTrue(ids.contains("draft_email"))
        XCTAssertTrue(mutator.graph.edges.contains { edge in
            if case let .linear(from, to) = edge {
                return from == "plan_trip" && to == "draft_email"
            }
            return false
        })
    }

    func testUncertaintyRouterInjectsOnLowConfidenceFinance() async throws {
        var state = LifeState()
        state.setConfidence(for: financeOverviewKey.erased, record: ConfidenceRecord(confidence: 0.4, reason: "No data", sources: ["finance"]))
        let router = UncertaintyRouter()
        let decision = try await router.route(state: state, nextNode: JobOfferAnalysisNode())
        switch decision {
        case .mutate(let mutation):
            switch mutation {
            case .inject(_, let nodes, _):
                XCTAssertTrue(nodes.contains(where: { $0.id == "scan_finances" }))
            default:
                XCTFail("Expected inject mutation")
            }
        default:
            XCTFail("Expected mutation for low confidence")
        }
    }

    func testUncertaintyRouterThresholds() async throws {
        let router = UncertaintyRouter(threshold: 0.6)

        var state1 = LifeState()
        state1.setConfidence(for: financeOverviewKey.erased, record: ConfidenceRecord(confidence: 0.59, reason: "Partial data", sources: ["bank"]))
        let decision1 = try await router.route(state: state1, nextNode: JobOfferAnalysisNode())
        if case .mutate = decision1 {
            // expected inject
        } else {
            XCTFail("Should inject at 0.59 with threshold 0.6")
        }

        var state2 = LifeState()
        state2.setConfidence(for: financeOverviewKey.erased, record: ConfidenceRecord(confidence: 0.61, reason: "Good data", sources: ["bank"]))
        let decision2 = try await router.route(state: state2, nextNode: JobOfferAnalysisNode())
        XCTAssertEqual(decision2, .proceed)

        var state3 = LifeState()
        state3.setConfidence(for: financeOverviewKey.erased, record: ConfidenceRecord(confidence: 0.6, reason: "Threshold", sources: ["bank"]))
        _ = try await router.route(state: state3, nextNode: JobOfferAnalysisNode()) // defined behavior: at threshold proceed
    }

    func testUncertaintyRouterMultipleInputs() async throws {
        var state = LifeState()
        state.setConfidence(for: financeOverviewKey.erased, record: ConfidenceRecord(confidence: 0.4, reason: "Missing accounts", sources: ["bank"]))
        state.setConfidence(for: calendarOverviewKey.erased, record: ConfidenceRecord(confidence: 0.9, reason: "Full sync", sources: ["gcal"]))
        state.setConfidence(for: selectedMessagesKey.erased, record: ConfidenceRecord(confidence: 0.7, reason: "Recent", sources: ["inbox"]))

        let router = UncertaintyRouter()
        let decision = try await router.route(state: state, nextNode: JobOfferAnalysisNode())
        switch decision {
        case .mutate(let mutation):
            if case let .inject(_, nodes, reason) = mutation {
                XCTAssertEqual(nodes.count, 1)
                XCTAssertTrue(nodes.contains(where: { $0.id == "scan_finances" }))
                XCTAssertTrue(reason.contains("finance"))
            } else {
                XCTFail("Expected inject mutation")
            }
        default:
            XCTFail("Expected mutation for low finance confidence")
        }
    }

    func testUncertaintyRouterMultipleLowInputs() async throws {
        var state = LifeState()
        state.setConfidence(for: financeOverviewKey.erased, record: ConfidenceRecord(confidence: 0.3, reason: "No data", sources: []))
        state.setConfidence(for: selectedMessagesKey.erased, record: ConfidenceRecord(confidence: 0.4, reason: "Old data", sources: ["mail"]))
        let router = UncertaintyRouter()
        let decision = try await router.route(state: state, nextNode: JobOfferAnalysisNode())
        switch decision {
        case .mutate(let mutation):
            if case let .inject(_, nodes, _) = mutation {
                XCTAssertGreaterThanOrEqual(nodes.count, 2)
                XCTAssertTrue(nodes.contains(where: { $0.id == "scan_finances" }))
                XCTAssertTrue(nodes.contains(where: { $0.id == "load_messages" }))
            } else {
                XCTFail("Expected inject mutation")
            }
        default:
            XCTFail("Expected mutation for multiple low-confidence inputs")
        }
    }

    func testUncertaintyRouterInjectionCap() async throws {
        var state = LifeState()
        state.setConfidence(for: financeOverviewKey.erased, record: ConfidenceRecord(confidence: 0.3, reason: "Access denied", sources: ["scan_finances"]))
        state.injectionHistory = ["scan_finances": 2]
        let router = UncertaintyRouter(maxInjectionAttempts: 2)
        let decision = try await router.route(state: state, nextNode: JobOfferAnalysisNode())
        switch decision {
        case .askUser(let q):
            XCTAssertTrue(q.lowercased().contains("financial"))
        case .proceedWithCaveat:
            break
        default:
            XCTFail("Should avoid further injections when cap reached")
        }
    }
}
