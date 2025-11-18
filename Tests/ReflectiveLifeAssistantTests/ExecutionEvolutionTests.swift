import XCTest
@testable import ReflectiveLifeAssistant

final class ExecutionEvolutionTests: XCTestCase {

    func testExecutionMemoryRecordsAndRetrievesSimilar() async throws {
        let memory = ExecutionMemory()
        let trace = ExecutionTrace(
            taskDescription: "Plan weekend trip",
            generatedGraph: fallbackGraphConfig(now: Date()),
            actualExecutionPath: ["scan_calendar", "plan_trip"],
            executionTimes: [:],
            reflectionLoops: [],
            userInterventions: [],
            finalOutcome: .success,
            timestamp: Date()
        )
        memory.record(trace)
        let results = try await memory.findSimilar(to: "Plan trip", limit: 1)
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.task, "Plan weekend trip")
    }

    func testGraphEvolverFallsBackOnParsingError() async throws {
        let registry = NodeRegistry()
        registry.register(ScanFinancesNode())
        registry.register(JobOfferAnalysisNode())
        let memory = ExecutionMemory()
        let badLLM = MockLLMClient(response: "not json")
        let evolver = GraphEvolver(llm: badLLM, nodeRegistry: registry, memory: memory)
        let result = try await evolver.buildGraphForTask("Analyze job offer", context: [:])
        XCTAssertFalse(result.config.nodes.isEmpty)
    }

    func testRecordTraceStoresOutcome() {
        let memory = ExecutionMemory()
        let graph = fallbackGraphConfig(now: Date())
        let state = LifeState([
            actionPathKey.name: ["a", "b"],
            actionPlanSummaryKey.name: "done"
        ])
        let outcome: OutcomeRating = (state[actionPlanSummaryKey] != nil) ? .success : .partial
        let trace = ExecutionTrace(
            taskDescription: "Test",
            generatedGraph: graph,
            actualExecutionPath: state.actionPath,
            executionTimes: [:],
            reflectionLoops: [],
            userInterventions: [],
            finalOutcome: outcome,
            timestamp: Date()
        )
        memory.record(trace)
        XCTAssertEqual(memory.traces.count, 1)
        XCTAssertEqual(memory.traces.first?.finalOutcome, .success)
    }
}
