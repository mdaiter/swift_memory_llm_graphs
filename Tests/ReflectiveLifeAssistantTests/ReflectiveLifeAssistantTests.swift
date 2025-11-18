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
}
