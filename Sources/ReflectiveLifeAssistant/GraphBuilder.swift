import Foundation
import LangGraph

enum GraphBuilderError: Error {
    case missingRequiredInput(node: String, key: String)
}

enum Edge {
    case linear(from: String, to: String)
    case parallel(from: String, tos: [String])
    case keyed(from: String, key: StateKey<String>, mapping: [String: String], fallback: String)
    case keyedDynamic(from: String, keyName: String, mapping: [String: String], fallback: String)
}

struct GraphConfig {
    let nodes: [DomainNode]
    let edges: [Edge]
    let reflectionPoints: [String: ReflectionCriteria]
    let entryNode: String
}

    final class GraphBuilder {
    func build(config: GraphConfig, context: ExecutionContext) throws -> StateGraph<LifeState>.CompiledGraph {
        let graph = StateGraph<LifeState>(stateFactory: LifeState.init)
        var addedEdges = Set<String>()
        let allowedNodes = Set(config.nodes.map { $0.id }).union([START, END])

        for node in config.nodes {
            try graph.addNode(node.id, action: { state in
                try self.validate(node: node, state: state)
                var updates = try await node.execute(state: state, context: context)

                // Track the visited path for observability.
                var path = state.actionPath
                path.append(node.id)
                updates[actionPathKey.name] = path

                // Apply node-specific reflection criteria declaratively.
                var newState = LifeState(state.data)
                newState.data.merge(updates) { _, new in new }
                if let criteria = config.reflectionPoints[node.id] {
                    let action = criteria.evaluate(newState)
                    let reflectionUpdates = self.reflectionUpdates(
                        state: state,
                        level: .execution,
                        result: action
                    )
                    updates.merge(reflectionUpdates) { _, new in new }
                }

                return updates
            })
        }

        for edge in config.edges {
            switch edge {
            case let .linear(from, to):
                guard allowedNodes.contains(from) && allowedNodes.contains(to) else { continue }
                let key = "\(from)->\(to)"
                if !addedEdges.contains(key) {
                    do {
                        try graph.addEdge(sourceId: from, targetId: to)
                        addedEdges.insert(key)
                    } catch {
                        if "\(error)".contains("duplicateEdgeError") {
                            // Ignore duplicate edges produced by synthesis.
                        } else {
                            throw error
                        }
                    }
                }
            case let .parallel(from, tos):
                guard allowedNodes.contains(from) else { continue }
                for to in tos {
                    guard allowedNodes.contains(to) else { continue }
                    let key = "\(from)->\(to)"
                    if !addedEdges.contains(key) {
                        do {
                            try graph.addEdge(sourceId: from, targetId: to)
                            addedEdges.insert(key)
                        } catch {
                            if "\(error)".contains("duplicateEdgeError") {
                                continue
                            } else {
                                throw error
                            }
                        }
                    }
                }
            case let .keyed(from, key, mapping, fallback):
                guard allowedNodes.contains(from) else { continue }
                var edgeMapping = mapping
                edgeMapping[fallback] = fallback
                edgeMapping = edgeMapping.filter { allowedNodes.contains($0.value) }
                if edgeMapping.isEmpty { continue }
                try graph.addConditionalEdge(
                    sourceId: from,
                    condition: { state in
                        let value = state[key] ?? fallback
                        return mapping[value] ?? fallback
                    },
                    edgeMapping: edgeMapping
                )
            case let .keyedDynamic(from, keyName, mapping, fallback):
                guard allowedNodes.contains(from) else { continue }
                var edgeMapping = mapping
                edgeMapping[fallback] = fallback
                edgeMapping = edgeMapping.filter { allowedNodes.contains($0.value) }
                if edgeMapping.isEmpty { continue }
                try graph.addConditionalEdge(
                    sourceId: from,
                    condition: { state in
                        let value = state.data[keyName] as? String ?? fallback
                        return mapping[value] ?? fallback
                    },
                    edgeMapping: edgeMapping
                )
            }
        }

        // Ensure there is an entry point from START to the configured entry node.
        if !config.edges.contains(where: { edge in
            if case let .linear(from, to) = edge {
                return from == START && to == config.entryNode
            }
            return false
        }) {
            let key = "\(START)->\(config.entryNode)"
            if !addedEdges.contains(key), allowedNodes.contains(config.entryNode) {
                do {
                    try graph.addEdge(sourceId: START, targetId: config.entryNode)
                    addedEdges.insert(key)
                } catch {
                    // Ignore duplicate start edges.
                }
            }
        }

        return try graph.compile()
    }

    private func validate(node: DomainNode, state: LifeState) throws {
        for key in node.inputRequirements {
            if state.data[key.name] == nil {
                throw GraphBuilderError.missingRequiredInput(node: node.id, key: key.name)
            }
        }
    }

    private func reflectionUpdates(state: LifeState, level: ReflectionLevel, result: ReflectionResult) -> [String: Any] {
        var updates: [String: Any] = [
            reflectionLevelKey.name: level.rawValue,
            reflectionCountKey.name: (state[reflectionCountKey] ?? 0) + 1
        ]

        switch result {
        case .success:
            updates[reflectionActionKey.name] = "success"
        case let .refine(target, reason):
            updates[reflectionActionKey.name] = "refine"
            updates[reflectionReasonKey.name] = reason
            updates[nextNodeKey.name] = target
        case let .escalate(reason):
            updates[reflectionActionKey.name] = "escalate"
            updates[reflectionReasonKey.name] = reason
            updates[nextNodeKey.name] = "request_user_input"
        case let .requestUserInput(question):
            updates[reflectionActionKey.name] = "need_input"
            updates[reflectionReasonKey.name] = question
            updates[nextNodeKey.name] = "request_user_input"
        }

        return updates
    }
}
