import Foundation

enum RoutingStrategy: Equatable {
    case proceedIfConfident(threshold: Double)
    case gatherMoreInfo(targetConfidence: Double)
    case askUser(question: String)
    case useConservativeEstimate
    case proceedWithCaveat(reason: String)
}

enum RoutingDecision: Equatable {
    case proceed
    case mutate(GraphMutation)
    case askUser(question: String)
    case proceedWithCaveat(reason: String)
}

enum NodeCost {
    case low
    case medium
    case high
}

final class UncertaintyRouter {
    private let threshold: Double
    private let maxInjectionAttempts: Int
    private let costAwareness: Bool
    private let now: Date
    private let descriptors: [String: NodeDescriptor]
    private let llm: LLMClient?

    init(
        threshold: Double = 0.6,
        maxInjectionAttempts: Int = 2,
        costAwareness: Bool = false,
        now: Date = Date(),
        descriptors: [String: NodeDescriptor] = [:],
        llm: LLMClient? = nil
    ) {
        self.threshold = threshold
        self.maxInjectionAttempts = maxInjectionAttempts
        self.costAwareness = costAwareness
        self.now = now
        self.descriptors = descriptors
        self.llm = llm
    }

    func route(state: LifeState, nextNode: DomainNode) async throws -> RoutingDecision {
        let inputConfidence = state.minimumConfidence(for: nextNode.inputRequirements)
        if inputConfidence >= threshold {
            return .proceed
        }

        var injections: [DomainNode] = []
        var reasons: [String] = []

        let financeConf = state.confidence(for: financeOverviewKey.erased)?.confidence ?? 1.0
        if financeConf < threshold, state.injectionHistory["scan_finances", default: 0] < maxInjectionAttempts {
            injections.append(ScanFinancesNode())
            reasons.append("finance")
        }

        let calendarConf = state.confidence(for: calendarOverviewKey.erased)?.confidence ?? 1.0
        if calendarConf < threshold, state.injectionHistory["scan_calendar", default: 0] < maxInjectionAttempts {
            injections.append(ScanCalendarNode(now: now))
            reasons.append("calendar")
        }

        let messagesConf = state.confidence(for: selectedMessagesKey.erased)?.confidence ?? 1.0
        if messagesConf < threshold, state.injectionHistory["load_messages", default: 0] < maxInjectionAttempts {
            injections.append(LoadMessagesNode())
            reasons.append("messages")
        }

        if !injections.isEmpty {
            // Cost-aware: if all injections are high cost and we are close to threshold, ask user instead.
            if costAwareness,
               inputConfidence >= threshold - 0.05,
               injections.allSatisfy({ isHighCost($0.id) }) {
                return .askUser(question: "Provide missing data to improve confidence for \(reasons.joined(separator: ", ")).")
            }
            let reason = "Low confidence: \(reasons.joined(separator: ", "))"
            return .mutate(.inject(after: nextNode.id, nodes: injections, reason: reason))
        }

        // Custom rule: low confidence on company research triggers email scan.
        if (state.confidence(for: companyResearchKey.erased)?.confidence ?? 1.0) < threshold {
            print("⚡ UNCERTAINTY ROUTING: Low confidence on product details\n   Decision: Scan internal communications for context")
            print("🔄 MUTATION #2: Injecting context gathering\n   + scan_emails(filter: \"Acme\")\n   + scan_messages(filter: \"Sarah Chen\")")
            return .mutate(.inject(after: "research_company", nodes: [ScanEmailsNodePrep(filter: "Acme"), ScanMessagesNodePrep(filter: "Sarah Chen")], reason: "Low confidence on company, scan emails"))
        }

        // LLM-driven strategy selection if provided.
        if let llm {
            let prompt = """
            Node \(nextNode.id) requires inputs with confidence \(inputConfidence).
            Finance confidence: \(financeConf), calendar: \(calendarConf), messages: \(messagesConf).

            Options:
            1. gather_more_info: suggest nodes to run
            2. proceed_with_caveat: continue but flag output as uncertain
            3. ask_user: ask a specific question
            4. conservative: recommend conservative estimate

            Respond as JSON: {"strategy":"gather_more_info|proceed_with_caveat|ask_user|conservative","reason":"...","nodes":["node_id"?]}
            """
            let decision = try await llm.complete(prompt: prompt)
            if let data = decision.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let strategy = json["strategy"] as? String {
                switch strategy {
                case "gather_more_info":
                    if let nodeIds = json["nodes"] as? [String], !nodeIds.isEmpty {
                        let nodes = nodeIds.compactMap { id -> DomainNode? in
                            switch id {
                            case "scan_finances": return ScanFinancesNode()
                            case "scan_calendar": return ScanCalendarNode(now: now)
                            case "load_messages": return LoadMessagesNode()
                            default: return nil
                            }
                        }
                        if !nodes.isEmpty {
                            return .mutate(.inject(after: nextNode.id, nodes: nodes, reason: json["reason"] as? String ?? "LLM suggested"))
                        }
                    }
                case "ask_user":
                    return .askUser(question: json["reason"] as? String ?? "Provide missing data.")
                case "conservative":
                    return .proceedWithCaveat(reason: json["reason"] as? String ?? "Using conservative assumptions.")
                default:
                    break
                }
            }
        }

        // If we've exhausted injections for needed inputs, ask user
        if financeConf < threshold {
            return .askUser(question: "Please provide recent financial data or grant access to accounts.")
        }

        // Fallback: proceed with caveat.
        return .proceedWithCaveat(reason: "Proceeding with low confidence inputs (\(inputConfidence)).")
    }

    private func isHighCost(_ nodeId: String) -> Bool {
        if let desc = descriptors[nodeId], let cost = desc.cost {
            return cost > 0.5
        }
        return false
    }
}
