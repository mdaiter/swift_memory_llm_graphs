import Dispatch
import Foundation
import LangGraph
import OpenAIKit

// MARK: - Demo wiring using GraphQueryBuilder + LearningGraphBuilder

func runApp() async {
    let userTask = ProcessInfo.processInfo.environment["USER_TASK"] ?? """
    Help me plan a Mexico trip for my 30th birthday, reply to my inbox in my tone, and analyze a new job offer from Contoso.
    """

    let llm: LLMClient
    if let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !apiKey.isEmpty {
        do {
            llm = try OpenAILLMClient(apiKey: apiKey, model: Model.GPT3.gpt3_5Turbo16K)
        } catch {
            print("Error configuring OpenAI client: \(error)")
            return
        }
    } else {
        print("⚠️ OPENAI_API_KEY not set; using MockLLMClient for offline demo.")
        llm = MockLLMClient(response: """
        {"reasoning":"fallback","estimated_cost":{"time_seconds":5,"api_calls":2,"confidence":0.5},"graph":{"nodes":["load_messages","infer_style","plan_trip","draft_email","generate_life_audit"],"edges":[{"type":"linear","from":"START","to":"load_messages"},{"type":"linear","from":"load_messages","to":"infer_style"},{"type":"linear","from":"infer_style","to":"plan_trip"},{"type":"linear","from":"plan_trip","to":"draft_email"},{"type":"linear","from":"draft_email","to":"generate_life_audit"},{"type":"linear","from":"generate_life_audit","to":"END"}],"entry_node":"load_messages"}}
        """)
    }

    let store = MessageStore(messages: [
        Message(id: "1", from: "alice", subject: "Trip tips", body: "Mexico birthday ideas", isUnread: true, isImportant: true),
        Message(id: "2", from: "bob", subject: "Inbox", body: "Unread messages to answer", isUnread: true, isImportant: true),
        Message(id: "3", from: "carol", subject: "Job offer", body: "Consider the offer I sent", isUnread: true, isImportant: true)
    ])

    let fileClient = MockFileSystemClient(files: [
        FileSummary(path: "/docs/a.pdf", sizeBytes: 1_200_000, modifiedAt: Date(), kind: "pdf"),
        FileSummary(path: "/docs/b.jpg", sizeBytes: 800_000, modifiedAt: Date(), kind: "image")
    ])
    let calendarClient = MockCalendarClient(events: [
        CalendarEvent(id: "1", title: "Flight to CDMX", startsAt: Date().addingTimeInterval(5 * 24 * 3600), endsAt: Date().addingTimeInterval(5 * 24 * 3600 + 7200), location: nil),
        CalendarEvent(id: "2", title: "Friend dinner", startsAt: Date().addingTimeInterval(8 * 24 * 3600), endsAt: Date().addingTimeInterval(8 * 24 * 3600 + 3600), location: nil)
    ])
    let financeClient = MockFinanceClient(transactions: [
        Transaction(id: "t1", date: Date(), amount: -400.0, description: "Flight ticket", category: "travel"),
        Transaction(id: "t2", date: Date(), amount: -150.0, description: "Groceries", category: "food"),
        Transaction(id: "t3", date: Date(), amount: 2000.0, description: "Salary", category: "income")
    ])

    let now = Date()
    let registry = NodeRegistry()
    let nodes = makeNodes(now: now)
    registerNodes(registry, nodes: nodes)

    let historyStore = InMemoryExecutionHistoryStore(records: [
        ExecutionRecord(task: "Plan weekend trip", summary: "Retry for missing budget", outcome: "Failed then fixed", improvements: "Add scan_finances before planning"),
        ExecutionRecord(task: "Reply urgent email", summary: "Tone issues", outcome: "Needed retries", improvements: "Add infer_style before drafting")
    ])

    let graphBuilder = GraphBuilder()
    let synthesis: GraphSynthesisResult
    do {
        // Try learning-driven synthesis first.
        let learning = LearningGraphBuilder(llm: llm, nodeRegistry: registry, executionHistory: historyStore)
        synthesis = try await learning.buildGraphForTask(userTask)
    } catch {
        print("⚠️ Graph synthesis failed (\(error)); falling back to static graph.")
        synthesis = GraphSynthesisResult(
            config: fallbackGraphConfig(now: now),
            reasoning: "Fallback graph because synthesis failed",
            estimatedCost: EstimatedCost(timeSeconds: nil, apiCalls: nil, confidence: nil)
        )
    }

    // Ensure inferred nodes exist in the registry. If the synthesis graph mentions nodes we do not have,
    // fall back to the static graph to avoid missingEdge errors.
    let synthesizedNodeIds = Set(synthesis.config.nodes.map { $0.id })
    let expectedNodeIds = Set(registry.catalog().map { $0.id })
    let missingInRegistry = synthesizedNodeIds.subtracting(expectedNodeIds)
    let missingByEdge = synthesis.config.edges.compactMap { edge -> String? in
        switch edge {
        case let .linear(from, to):
            if !expectedNodeIds.contains(from) { return from }
            if !expectedNodeIds.contains(to) { return to }
            return nil
        case let .parallel(from, tos):
            if !expectedNodeIds.contains(from) { return from }
            let missing = tos.first(where: { !expectedNodeIds.contains($0) })
            return missing
        case let .keyed(from, _, mapping, fallback):
            if !expectedNodeIds.contains(from) { return from }
            let missing = mapping.values.first(where: { !expectedNodeIds.contains($0) }) ?? (expectedNodeIds.contains(fallback) ? nil : fallback)
            return missing
        case let .keyedDynamic(from, _, mapping, fallback):
            if !expectedNodeIds.contains(from) { return from }
            let missing = mapping.values.first(where: { !expectedNodeIds.contains($0) }) ?? (expectedNodeIds.contains(fallback) ? nil : fallback)
            return missing
        }
    }.compactMap { $0 }

    var effectiveConfig = synthesis.config
    if !missingInRegistry.isEmpty || !missingByEdge.isEmpty {
        print("⚠️ Synthesized graph references unknown nodes: \(missingInRegistry.union(missingByEdge)) — using fallback graph.")
        effectiveConfig = fallbackGraphConfig(now: now)
    }

    if let template = try? await GraphQueryBuilder(llm: llm, nodeRegistry: registry).selectTemplate(for: userTask) {
        print("📐 Selected template: \(template.rawValue)")
    }

    print("🧭 Graph reasoning:\n\(synthesis.reasoning)")
    if let confidence = synthesis.estimatedCost.confidence {
        print("💰 Estimated cost: \(synthesis.estimatedCost.timeSeconds ?? 0)s, API calls: \(synthesis.estimatedCost.apiCalls ?? 0), confidence: \(confidence)")
    }

    let context = ExecutionContext(
        llm: llm,
        messageStore: store,
        fileSystem: fileClient,
        calendar: calendarClient,
        finance: financeClient,
        evaluationGenerator: LLMEvaluationGenerator(llm: llm)
    )

    do {
        let compiled = try graphBuilder.build(config: effectiveConfig, context: context)
        let finalState = try await compiled.invoke(inputs: [
            userRequestKey.name: userTask
        ])
        print("Action path: \(renderAsciiPath(from: finalState.actionPath))")
        print("Trip plan summary: \(finalState[tripPlanKey]?.summary ?? "N/A")")
        print("Drafted replies: \((finalState[draftedRepliesKey] ?? []).prefix(2))")
        print("Job analysis: \(finalState[jobOfferAnalysisKey]?.recommendation ?? "None")")
        if let summary = finalState[actionPlanSummaryKey] {
            print("Action plan summary:\n\(summary)")
        }
        print("Reflections: \(finalState[reflectionCountKey] ?? 0)")
        if ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil {
            let runSummary = try await summarizeRun(llm: llm, state: finalState)
            print("\nRun summary:\n\(runSummary)")
        }
    } catch {
        print("Error executing synthesized graph: \(error). Using fallback graph.")
        do {
            let compiled = try graphBuilder.build(config: fallbackGraphConfig(now: now), context: context)
            let finalState = try await compiled.invoke(inputs: [
                userRequestKey.name: userTask
            ])
            print("Action path: \(renderAsciiPath(from: finalState.actionPath))")
            print("Trip plan summary: \(finalState[tripPlanKey]?.summary ?? "N/A")")
            print("Drafted replies: \((finalState[draftedRepliesKey] ?? []).prefix(2))")
            print("Job analysis: \(finalState[jobOfferAnalysisKey]?.recommendation ?? "None")")
            if let summary = finalState[actionPlanSummaryKey] {
                print("Action plan summary:\n\(summary)")
            }
            print("Reflections: \(finalState[reflectionCountKey] ?? 0)")
        } catch {
            print("Fallback graph execution failed:", error)
        }
    }
}

let semaphore = DispatchSemaphore(value: 0)
_Concurrency.Task {
    await runApp()
    semaphore.signal()
}
semaphore.wait()
