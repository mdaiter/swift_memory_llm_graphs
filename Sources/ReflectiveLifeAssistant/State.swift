import Foundation
import LangGraph

// MARK: - Typed, extensible state

protocol StateValue: Codable {}

extension String: StateValue {}
extension Int: StateValue {}
extension Double: StateValue {}
extension Bool: StateValue {}
extension Array: StateValue where Element: StateValue {}
extension Dictionary: StateValue where Key == String, Value: StateValue {}

struct AnyStateKey: Hashable {
    let name: String
}

struct StateKey<T: StateValue>: Hashable {
    let name: String

    init(_ name: String) {
        self.name = name
    }

    var erased: AnyStateKey { AnyStateKey(name: name) }
}

struct TypedState {
    fileprivate var storage: [String: Any]

    init(_ initial: [String: Any] = [:]) {
        self.storage = initial
    }

    subscript<T: StateValue>(key: StateKey<T>) -> T? {
        get { storage[key.name] as? T }
        set { storage[key.name] = newValue }
    }

    mutating func merge(_ updates: [String: Any]) {
        updates.forEach { storage[$0.key] = $0.value }
    }

    var raw: [String: Any] { storage }
}

struct LifeState: AgentState {
    private var typed: TypedState

    init(_ initial: [String: Any] = [:]) {
        self.typed = TypedState(initial)
    }

    var data: [String: Any] {
        get { typed.raw }
        set { typed = TypedState(newValue) }
    }

    subscript<T: StateValue>(key: StateKey<T>) -> T? {
        get { typed[key] }
        set { typed[key] = newValue }
    }

    var actionPath: [String] {
        get { self[actionPathKey] ?? [] }
        set { self[actionPathKey] = newValue }
    }

    var userRequest: String {
        get { self[userRequestKey] ?? "" }
        set { self[userRequestKey] = newValue }
    }

    func confidence(for key: AnyStateKey) -> ConfidenceRecord? {
        self[confidenceMapKey]?[key.name]
    }

    func minimumConfidence(for keys: [AnyStateKey]) -> Double {
        let records = keys.compactMap { confidence(for: $0) }
        guard !records.isEmpty else { return 1.0 }
        return records.map { $0.confidence }.min() ?? 1.0
    }

    mutating func setConfidence(for key: AnyStateKey, record: ConfidenceRecord) {
        var map = self[confidenceMapKey] ?? [:]
        map[key.name] = record
        self[confidenceMapKey] = map
    }

    var injectionHistory: [String: Int] {
        get { self[injectionHistoryKey] ?? [:] }
        set { self[injectionHistoryKey] = newValue }
    }

    var nodeMetadata: [String: NodeMetadata] {
        get { self[nodeMetadataKey] ?? [:] }
        set { self[nodeMetadataKey] = newValue }
    }

    var executedNodes: [String] {
        get { actionPath }
        set { actionPath = newValue }
    }
}

// MARK: - Domain state models

struct TripPlan: Codable, Equatable, StateValue {
    let summary: String
}

struct JobOfferAnalysis: Codable, Equatable, StateValue {
    let highlights: String
    let risks: String
    let recommendation: String
}

struct ConfidenceRecord: Codable, Equatable, StateValue {
    let confidence: Double
    let reason: String
    let sources: [String]
}

struct ConfidentValue<T: StateValue & Equatable>: Codable, Equatable, StateValue {
    let value: T
    let confidence: Double
    let reason: String
    let sources: [String]
}

struct Attendee: Codable, Equatable, StateValue {
    let name: String
    let email: String
    let role: String
}

struct MeetingDetails: Codable, Equatable, StateValue {
    let title: String
    let time: String
    let attendees: [Attendee]
}

struct CompanyResearch: Codable, Equatable, StateValue {
    let name: String
    let description: String
    let stage: String
    let funding: String
    let productDetails: String?
}

struct PersonBio: Codable, Equatable, StateValue {
    let name: String
    let headline: String
    let highlights: [String]
}

struct NodeMetadata: Codable, Equatable, StateValue {
    let estimatedCost: String?
    let estimatedTimeMs: Int?
}

// MARK: - State keys

let userRequestKey = StateKey<String>("user_request")
let selectedMessagesKey = StateKey<[Message]>("selected_messages")
let styleSummaryKey = StateKey<String>("style_summary")
let tripPlanKey = StateKey<TripPlan>("trip_plan")
let draftedRepliesKey = StateKey<[String]>("drafted_replies")
let extractedTasksKey = StateKey<[Task]>("extracted_tasks")
let prioritizedTasksKey = StateKey<[Task]>("prioritized_tasks")
let actionPlanSummaryKey = StateKey<String>("action_plan_summary")
let actionPathKey = StateKey<[String]>("action_path")
let fileOverviewKey = StateKey<String>("file_overview")
let calendarOverviewKey = StateKey<String>("calendar_overview")
let financeOverviewKey = StateKey<String>("finance_overview")
let reflectionCountKey = StateKey<Int>("reflection_count")
let reflectionActionKey = StateKey<String>("reflection_action")
let reflectionReasonKey = StateKey<String>("reflection_reason")
let reflectionLevelKey = StateKey<String>("reflection_level")
let nextNodeKey = StateKey<String>("next_node")
let jobOfferAnalysisKey = StateKey<JobOfferAnalysis>("job_offer_analysis")
let confidenceMapKey = StateKey<[String: ConfidenceRecord]>("confidence_map")
let injectionHistoryKey = StateKey<[String: Int]>("injection_history")
let nodeMetadataKey = StateKey<[String: NodeMetadata]>("node_metadata")
let meetingDetailsKey = StateKey<MeetingDetails>("meeting_details")
let companyResearchKey = StateKey<CompanyResearch>("company_research")
let painPointsKey = StateKey<[String]>("pain_points")
let talkingPointsKey = StateKey<[String]>("talking_points")
let competitorAnalysisKey = StateKey<String>("competitor_analysis")
let caseStudiesKey = StateKey<[String]>("case_studies")
let personResearchKey = StateKey<[String: PersonBio]>("person_research")
