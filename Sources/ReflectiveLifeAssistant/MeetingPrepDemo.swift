import Foundation
import LangGraph

// MARK: - Meeting prep nodes

struct ScanCalendarMeetingNode: DomainNode {
    let id = "scan_calendar_meeting"
    let inputRequirements: [AnyStateKey] = []
    let outputKeys: [AnyStateKey] = [meetingDetailsKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        print("[scan_calendar] ✓ Found meeting at 3pm")
        let details = MeetingDetails(
            title: "Product Demo - Acme Corp",
            time: "3:00 PM",
            attendees: [
                Attendee(name: "Sarah Chen", email: "sarah@acme.com", role: "CEO"),
                Attendee(name: "Mike Johnson", email: "mike@acme.com", role: "CTO"),
                Attendee(name: "Unknown", email: "eng@acme.com", role: "Unknown")
            ]
        )
        var updates: [String: Any] = [meetingDetailsKey.name: details]
        var mutable = state
        mutable.setConfidence(for: meetingDetailsKey.erased, record: ConfidenceRecord(confidence: 0.9, reason: "From calendar", sources: ["calendar"]))
        updates.merge(mutable.data.filter { $0.key == confidenceMapKey.name }) { _, new in new }
        return updates
    }
}

struct FindMeetingDetailsNode: DomainNode {
    let id = "find_meeting_details"
    let inputRequirements: [AnyStateKey] = [meetingDetailsKey.erased]
    let outputKeys: [AnyStateKey] = [meetingDetailsKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        guard let details = state[meetingDetailsKey] else { return [:] }
        print("[find_meeting_details]\n  ✓ Found: \"\(details.title)\"\n  ✓ Attendees: Sarah Chen (CEO), Mike Johnson (CTO), unknown@acme.com\n  ⚠️  Confidence: 0.5 (missing company context)")
        var updates: [String: Any] = [meetingDetailsKey.name: details]
        var mutable = state
        mutable.setConfidence(for: meetingDetailsKey.erased, record: ConfidenceRecord(confidence: 0.5, reason: "Missing company context", sources: ["calendar"]))
        updates.merge(mutable.data.filter { $0.key == confidenceMapKey.name }) { _, new in new }

        // Trigger mutation: inject research nodes.
        let mutation = GraphMutation.inject(
            after: id,
            nodes: [
                ResearchCompanyNode(companyName: "Acme Corp"),
                ResearchPersonNode(person: "Sarah Chen"),
                ResearchPersonNode(person: "Mike Johnson")
            ],
            reason: "Discovered \(details.attendees.count) attendees, need to research each"
        )
        context.requestMutation(mutation)
        print("🔄 MUTATION #1: Injecting research nodes")
        print("   + research_company(Acme Corp)\n   + research_person(Sarah Chen)\n   + research_person(Mike Johnson)")
        return updates
    }
}

struct ResearchCompanyNode: DomainNode {
    let id = "research_company"
    let companyName: String
    let inputRequirements: [AnyStateKey] = []
    let outputKeys: [AnyStateKey] = [companyResearchKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        print("[research_company]\n  ✓ Acme Corp: Series A, $10M raised, B2B SaaS\n  ⚠️  Confidence: 0.4 (can't find product details or pain points)")
        let research = CompanyResearch(
            name: "Acme Corp",
            description: "B2B SaaS platform for data integration",
            stage: "Series A",
            funding: "$10M",
            productDetails: nil
        )
        var updates: [String: Any] = [companyResearchKey.name: research]
        var mutable = state
        mutable.setConfidence(for: companyResearchKey.erased, record: ConfidenceRecord(confidence: 0.4, reason: "Missing product details", sources: ["open web"]))
        updates.merge(mutable.data.filter { $0.key == confidenceMapKey.name }) { _, new in new }
        return updates
    }
}

struct ResearchPersonNode: DomainNode {
    let id = "research_person"
    let person: String
    let inputRequirements: [AnyStateKey] = []
    let outputKeys: [AnyStateKey] = [personResearchKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let bio = PersonBio(name: person, headline: "Leader at Acme Corp", highlights: ["Built API platform", "Drives architecture"])
        var map = state[personResearchKey] ?? [:]
        map[person] = bio
        var updates: [String: Any] = [personResearchKey.name: map]
        var mutable = state
        mutable.setConfidence(for: AnyStateKey(name: "\(personResearchKey.name)_\(person)"), record: ConfidenceRecord(confidence: 0.7, reason: "From profile", sources: ["linkedin"]))
        updates.merge(mutable.data.filter { $0.key == confidenceMapKey.name }) { _, new in new }
        return updates
    }
}

struct ScanEmailsNodePrep: DomainNode {
    let id = "scan_emails"
    let filter: String
    let inputRequirements: [AnyStateKey] = []
    let outputKeys: [AnyStateKey] = [painPointsKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        print("[scan_emails]\n  ✓ Found: \"They're struggling with API rate limits on their current provider\"\n  ✓ Confidence: 0.8 → UPGRADED")
        let pains = [
            "Struggling with API rate limits on current provider (Competitor X)",
            "Need to scale 10x in Q1 to support new customer acquisition",
            "Looking for better observability and debugging tools"
        ]
        var updates: [String: Any] = [painPointsKey.name: pains]
        var mutable = state
        mutable.setConfidence(for: painPointsKey.erased, record: ConfidenceRecord(confidence: 0.8, reason: "Found in emails", sources: ["emails"]))
        updates.merge(mutable.data.filter { $0.key == confidenceMapKey.name }) { _, new in new }

        // Mutation: inject sales prep nodes.
        print("🔄 MUTATION #3: Discovered sales context → inject sales prep")
        print("   + research_competitors\n   + prepare_pricing_talking_points\n   + load_case_studies(similar_companies)")
        context.requestMutation(.inject(after: id, nodes: [
            PrepareCompetitorAnalysisNode(),
            PreparePricingTalkingPointsNode(),
            LoadCaseStudiesNode()
        ], reason: "Discovered sales context and pain points"))
        return updates
    }
}

struct ScanMessagesNodePrep: DomainNode {
    let id = "scan_messages"
    let filter: String
    let inputRequirements: [AnyStateKey] = []
    let outputKeys: [AnyStateKey] = []

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        print("[scan_messages]\n  ✓ Checked messages for \(filter)")
        return [:]
    }
}

struct PrepareCompetitorAnalysisNode: DomainNode {
    let id = "prepare_competitor_analysis"
    let inputRequirements: [AnyStateKey] = []
    let outputKeys: [AnyStateKey] = [competitorAnalysisKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let analysis = "vs Competitor X: 10x faster, better observability, similar pricing\nvs Competitor Y: More expensive but enterprise-grade reliability"
        var updates: [String: Any] = [competitorAnalysisKey.name: analysis]
        var mutable = state
        mutable.setConfidence(for: competitorAnalysisKey.erased, record: ConfidenceRecord(confidence: 0.9, reason: "Compiled comparison", sources: ["internal"]))
        updates.merge(mutable.data.filter { $0.key == confidenceMapKey.name }) { _, new in new }
        return updates
    }
}

struct PreparePricingTalkingPointsNode: DomainNode {
    let id = "prepare_pricing_talking_points"
    let inputRequirements: [AnyStateKey] = []
    let outputKeys: [AnyStateKey] = [talkingPointsKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let points = [
            "Our API scales to 100K req/sec (vs Competitor X's 10K limit)",
            "Built-in observability dashboard addresses their pain point",
            "99.99% uptime SLA for enterprise reliability"
        ]
        var updates: [String: Any] = [talkingPointsKey.name: points]
        var mutable = state
        mutable.setConfidence(for: talkingPointsKey.erased, record: ConfidenceRecord(confidence: 0.9, reason: "Prepared messaging", sources: ["playbook"]))
        updates.merge(mutable.data.filter { $0.key == confidenceMapKey.name }) { _, new in new }
        return updates
    }
}

struct LoadCaseStudiesNode: DomainNode {
    let id = "load_case_studies"
    let inputRequirements: [AnyStateKey] = []
    let outputKeys: [AnyStateKey] = [caseStudiesKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let cases = ["Contoso: Migrated from Competitor X and scaled 10x", "Northwind: Improved reliability with 99.99% SLA"]
        var updates: [String: Any] = [caseStudiesKey.name: cases]
        var mutable = state
        mutable.setConfidence(for: caseStudiesKey.erased, record: ConfidenceRecord(confidence: 0.8, reason: "Retrieved similar wins", sources: ["salesforce"]))
        updates.merge(mutable.data.filter { $0.key == confidenceMapKey.name }) { _, new in new }
        return updates
    }
}

struct GeneratePrepDocNode: DomainNode {
    let id = "generate_prep_doc"
    let inputRequirements: [AnyStateKey] = []
    let outputKeys: [AnyStateKey] = [actionPlanSummaryKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let doc = """
============================================================
📋 FINAL PREP DOCUMENT
============================================================
📅 Meeting: Product Demo - Acme Corp
⏰ Time: 3:00 PM
👥 Attendees: Sarah Chen (CEO), Mike Johnson (CTO), Unknown

🏢 Company Context:
  - Acme Corp: B2B SaaS platform for data integration
  - Stage: Series A, Funding: $10M

💡 Their Pain Points:
  - Struggling with API rate limits on current provider (Competitor X)
  - Need to scale 10x in Q1 to support new customers
  - Looking for better observability and debugging tools

🎯 Key Talking Points:
  - Our API scales to 100K req/sec (vs Competitor X's 10K limit)
  - Built-in observability dashboard addresses their pain point
  - 99.99% uptime SLA for enterprise reliability

⚔️  Competitive Positioning:
  vs Competitor X: 10x faster, better observability, similar pricing
  vs Competitor Y: More expensive but enterprise-grade reliability

📊 Execution Stats:
  - Initial nodes: 3
  - Final nodes: 9
  - Mutations: 3
  - Uncertainty interventions: 1
"""
        var updates: [String: Any] = [actionPlanSummaryKey.name: doc]
        var mutable = state
        mutable.setConfidence(for: actionPlanSummaryKey.erased, record: ConfidenceRecord(confidence: 1.0, reason: "Synthesized", sources: ["generate_prep_doc"]))
        updates.merge(mutable.data.filter { $0.key == confidenceMapKey.name }) { _, new in new }
        print("[generate_prep_doc]\n  ✓ Created comprehensive prep doc")
        return updates
    }
}

// MARK: - Meeting prep coordinator

struct PrepResult {
    let prepDocument: String
    let initialNodeCount: Int
    let finalNodeCount: Int
    let mutationCount: Int
    let uncertaintyInterventionCount: Int
    let executionTrace: [String]
}

final class MeetingPrepCoordinator {
    private let memory: ExecutionMemory

    init(memory: ExecutionMemory = ExecutionMemory()) {
        self.memory = memory
    }

    static func newNodes(from mutation: GraphMutation) -> [String] {
        switch mutation {
        case let .inject(_, nodes, _):
            return nodes.map { $0.id }
        default:
            return []
        }
    }

    func prepare(query: String) async throws -> PrepResult {
        let initialGraph = GraphConfig(
            nodes: [ScanCalendarMeetingNode(), FindMeetingDetailsNode(), GeneratePrepDocNode()],
            edges: [
                .linear(from: START, to: "scan_calendar_meeting"),
                .linear(from: "scan_calendar_meeting", to: "find_meeting_details"),
                .linear(from: "find_meeting_details", to: "generate_prep_doc"),
                .linear(from: "generate_prep_doc", to: END)
            ],
            reflectionPoints: [:],
            entryNode: "scan_calendar_meeting"
        )
        let visualizer = ASCIIGraphVisualizer()
        var configSnapshot = initialGraph
        let mutator = InMemoryGraphMutator(graph: initialGraph)
        let context = ExecutionContext(
            llm: MockLLMClient(response: "noop"),
            messageStore: MessageStore(messages: []),
            fileSystem: MockFileSystemClient(files: []),
            calendar: MockCalendarClient(events: []),
            finance: MockFinanceClient(transactions: []),
            evaluationGenerator: nil
        )
        var mutationCount = 0
        var uncertaintyCount = 0
        let router = UncertaintyRouter()
        print("📊 Initial Graph (\(configSnapshot.nodes.count) nodes)")
        print(visualizer.visualize(config: configSnapshot))
        print()
        let executor = AdaptiveExecutor(
            context: context,
            mutator: mutator,
            mutationDecider: nil,
            uncertaintyRouter: router,
            onMutation: { mutation in
                mutationCount += 1
                configSnapshot = mutator.graph
                let newNodes = MeetingPrepCoordinator.newNodes(from: mutation)
                print("\n🔄 After Mutation #\(mutationCount): \(mutation)")
                print("   (\(configSnapshot.nodes.count) nodes total)")
                print(visualizer.visualize(config: configSnapshot, highlight: newNodes))
                print()
            },
            onUncertaintyIntervention: { msg in
                uncertaintyCount += 1
                print("\n⚡ UNCERTAINTY ROUTING: \(msg)")
            }
        )
        let finalState = try await executor.execute(graph: initialGraph, inputs: [userRequestKey.name: query])
        let finalDoc = finalState[actionPlanSummaryKey] ?? "N/A"
        let result = PrepResult(
            prepDocument: finalDoc,
            initialNodeCount: 3,
            finalNodeCount: 9,
            mutationCount: mutationCount,
            uncertaintyInterventionCount: uncertaintyCount,
            executionTrace: finalState.actionPath
        )
        // Record trace in memory for future evolution.
        let trace = ExecutionTrace(
            taskDescription: query,
            generatedGraph: initialGraph,
            actualExecutionPath: finalState.actionPath,
            executionTimes: [:],
            reflectionLoops: [],
            userInterventions: [],
            finalOutcome: .success,
            timestamp: Date()
        )
        memory.record(trace)
        return result
    }
}

// MARK: - Demo runner

func runMeetingPrepDemo() async throws {
    let coordinator = MeetingPrepCoordinator()
    let result = try await coordinator.prepare(query: "Prepare me for my 3pm with Acme Corp")
    print(result.prepDocument)
    let path = (["START"] + result.executionTrace + ["END"]).joined(separator: " -> ")
    print("Action path: \(path)")
}

// Usage example:
// Task {
//    try await runMeetingPrepDemo()
// }
