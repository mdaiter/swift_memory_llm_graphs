import Foundation
import LangGraph

enum GraphMutation: Equatable {
    case inject(after: String, nodes: [DomainNode], reason: String)
    case prune(nodes: [String], reason: String)
    case reroute(from: String, to: String, reason: String)
    case none
}

extension GraphMutation {
    static func == (lhs: GraphMutation, rhs: GraphMutation) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.inject(la, lnodes, lr), .inject(ra, rnodes, rr)):
            return la == ra && lr == rr && lnodes.map { $0.id } == rnodes.map { $0.id }
        case let (.prune(ln, lr), .prune(rn, rr)):
            return Set(ln) == Set(rn) && lr == rr
        case let (.reroute(lf, lt, lr), .reroute(rf, rt, rr)):
            return lf == rf && lt == rt && lr == rr
        default:
            return false
        }
    }
}

protocol GraphMutator {
    var graph: GraphConfig { get }
    @discardableResult
    func injectNodes(after: String, nodes: [DomainNode], reason: String) async throws -> GraphConfig
    @discardableResult
    func pruneNodes(nodes: [String], reason: String) async throws -> GraphConfig
    @discardableResult
    func reroute(from: String, to: String, reason: String) async throws -> GraphConfig
}

final class InMemoryGraphMutator: GraphMutator {
    private(set) var graph: GraphConfig
    private(set) var mutationLog: [String] = []

    init(graph: GraphConfig) {
        self.graph = graph
    }

    @discardableResult
    func injectNodes(after: String, nodes: [DomainNode], reason: String) async throws -> GraphConfig {
        guard !nodes.isEmpty else { return graph }
        mutationLog.append("inject after \(after): \(reason)")

        var newNodes = graph.nodes
        for node in nodes where !newNodes.contains(where: { $0.id == node.id }) {
            newNodes.append(node)
        }

        var newEdges: [Edge] = []
        let outgoing = graph.edges.filter { edge in
            if case let .linear(from, _) = edge { return from == after }
            if case let .parallel(from, _) = edge { return from == after }
            return false
        }
        for edge in graph.edges {
            switch edge {
            case let .linear(from, to) where from == after:
                // Replace with chain through injected nodes.
                let first = nodes.first!.id
                let last = nodes.last!.id
                newEdges.append(.linear(from: from, to: first))
                newEdges.append(.linear(from: last, to: to))
            default:
                newEdges.append(edge)
            }
        }

        if outgoing.isEmpty {
            // No outgoing edges to splice; just append sequentially starting after the node.
            var previous = after
            for node in nodes {
                newEdges.append(.linear(from: previous, to: node.id))
                previous = node.id
            }
        }

        graph = GraphConfig(nodes: newNodes, edges: newEdges, reflectionPoints: graph.reflectionPoints, entryNode: graph.entryNode)
        return graph
    }

    @discardableResult
    func pruneNodes(nodes: [String], reason: String) async throws -> GraphConfig {
        mutationLog.append("prune \(nodes): \(reason)")
        let pruneSet = Set(nodes)
        let newNodes = graph.nodes.filter { !pruneSet.contains($0.id) }
        let newEdges = graph.edges.filter { edge in
            switch edge {
            case let .linear(from, to):
                return !pruneSet.contains(from) && !pruneSet.contains(to)
            case let .parallel(from, tos):
                return !pruneSet.contains(from) && tos.allSatisfy { !pruneSet.contains($0) }
            case let .keyed(from, _, mapping, fallback):
                return !pruneSet.contains(from) && !pruneSet.contains(fallback) && mapping.values.allSatisfy { !pruneSet.contains($0) }
            case let .keyedDynamic(from, _, mapping, fallback):
                return !pruneSet.contains(from) && !pruneSet.contains(fallback) && mapping.values.allSatisfy { !pruneSet.contains($0) }
            }
        }
        graph = GraphConfig(nodes: newNodes, edges: newEdges, reflectionPoints: graph.reflectionPoints, entryNode: graph.entryNode)
        return graph
    }

    @discardableResult
    func reroute(from: String, to: String, reason: String) async throws -> GraphConfig {
        mutationLog.append("reroute from \(from) to \(to): \(reason)")
        var newEdges = graph.edges.filter { edge in
            switch edge {
            case let .linear(src, _):
                return src != from
            case let .parallel(src, _):
                return src != from
            default:
                return true
            }
        }
        newEdges.append(.linear(from: from, to: to))
        graph = GraphConfig(nodes: graph.nodes, edges: newEdges, reflectionPoints: graph.reflectionPoints, entryNode: graph.entryNode)
        return graph
    }
}

final class AdaptiveExecutor {
    let context: ExecutionContext
    let mutator: GraphMutator
    let mutationDecider: ((DomainNode, LifeState, GraphConfig) async throws -> GraphMutation?)?
    let uncertaintyRouter: UncertaintyRouter?
    let onMutation: ((GraphMutation) -> Void)?
    let onUncertaintyIntervention: ((String) -> Void)?

    init(
        context: ExecutionContext,
        mutator: GraphMutator,
        mutationDecider: ((DomainNode, LifeState, GraphConfig) async throws -> GraphMutation?)? = nil,
        uncertaintyRouter: UncertaintyRouter? = nil,
        onMutation: ((GraphMutation) -> Void)? = nil,
        onUncertaintyIntervention: ((String) -> Void)? = nil
    ) {
        self.context = context
        self.mutator = mutator
        self.mutationDecider = mutationDecider
        self.uncertaintyRouter = uncertaintyRouter
        self.onMutation = onMutation
        self.onUncertaintyIntervention = onUncertaintyIntervention
    }

    func execute(graph: GraphConfig, inputs: [String: Any] = [:]) async throws -> LifeState {
        var mutableGraph = graph
        var state = LifeState(inputs)

        var visited = Set<String>()
        while true {
            let order = topologicalSort(config: mutableGraph)
            var mutated = false

            for nodeId in order where !visited.contains(nodeId) {
                guard let node = mutableGraph.nodes.first(where: { $0.id == nodeId }) else { continue }
                let updates = try await node.execute(state: state, context: context)
                var merged = state.data
                merged.merge(updates) { _, new in new }
                merged[actionPathKey.name, default: []] = (state.actionPath + [nodeId])
                state = LifeState(merged)
                visited.insert(nodeId)

                if let mutation = try await mutationDecider?(node, state, mutableGraph) {
                    switch mutation {
                    case let .inject(after, nodes, reason):
                        mutableGraph = try await mutator.injectNodes(after: after, nodes: nodes, reason: reason)
                        var history = state.injectionHistory
                        for n in nodes {
                            history[n.id, default: 0] += 1
                        }
                        state.injectionHistory = history
                    case let .prune(nodes, reason):
                        mutableGraph = try await mutator.pruneNodes(nodes: nodes, reason: reason)
                    case let .reroute(from, to, reason):
                        mutableGraph = try await mutator.reroute(from: from, to: to, reason: reason)
                    case .none:
                        break
                    }
                    onMutation?(mutation)
                    mutated = true
                    break // recompute order after mutation
                }

                // Apply any pending mutations requested by nodes.
                if !context.pendingMutations.isEmpty {
                    let mutations = context.pendingMutations
                    context.pendingMutations.removeAll()
                    for mutation in mutations {
                        switch mutation {
                        case let .inject(after, nodes, reason):
                            mutableGraph = try await mutator.injectNodes(after: after, nodes: nodes, reason: reason)
                        case let .prune(nodes, reason):
                            mutableGraph = try await mutator.pruneNodes(nodes: nodes, reason: reason)
                        case let .reroute(from, to, reason):
                            mutableGraph = try await mutator.reroute(from: from, to: to, reason: reason)
                        case .none:
                            break
                        }
                        onMutation?(mutation)
                    }
                    mutated = true
                    break
                }

                // Uncertainty routing hook: check next node in order if exists.
                if let router = uncertaintyRouter,
                   let nextIndex = order.firstIndex(of: nodeId)?.advanced(by: 1),
                   nextIndex < order.count,
                   let nextNode = mutableGraph.nodes.first(where: { $0.id == order[nextIndex] }) {
                    let decision = try await router.route(state: state, nextNode: nextNode)
                    switch decision {
                    case .mutate(let mutation):
                        switch mutation {
                        case let .inject(after, nodes, reason):
                            mutableGraph = try await mutator.injectNodes(after: after, nodes: nodes, reason: reason)
                        case let .prune(nodes, reason):
                            mutableGraph = try await mutator.pruneNodes(nodes: nodes, reason: reason)
                        case let .reroute(from, to, reason):
                            mutableGraph = try await mutator.reroute(from: from, to: to, reason: reason)
                        case .none:
                            break
                        }
                        onMutation?(mutation)
                        onUncertaintyIntervention?("Applied uncertainty mutation for \(nextNode.id)")
                        mutated = true
                        break
                    case .askUser(let msg):
                        onUncertaintyIntervention?("Ask user: \(msg)")
                    case .proceedWithCaveat(let msg):
                        onUncertaintyIntervention?("Proceed with caveat: \(msg)")
                    case .proceed:
                        break
                    }
                    if mutated { break }
                }
            }

            if !mutated { break }
        }

        return state
    }
}

// Simple BFS-style topological traversal respecting declared edges, ignoring START/END placeholders.
func topologicalSort(config: GraphConfig) -> [String] {
    var order: [String] = []
    var visited: Set<String> = []
    var queue: [String] = [config.entryNode]
    let adjacency: [String: [String]] = {
        var map: [String: [String]] = [:]
        for edge in config.edges {
            switch edge {
            case let .linear(from, to):
                map[from, default: []].append(to)
            case let .parallel(from, tos):
                map[from, default: []].append(contentsOf: tos)
            case let .keyed(_, _, mapping, _):
                mapping.forEach { fromValue, to in
                    map[fromValue, default: []].append(to)
                }
            case let .keyedDynamic(_, _, mapping, _):
                mapping.forEach { fromValue, to in
                    map[fromValue, default: []].append(to)
                }
            }
        }
        return map
    }()

    while !queue.isEmpty {
        let node = queue.removeFirst()
        if visited.contains(node) { continue }
        visited.insert(node)
        if node != START && node != END {
            order.append(node)
        }
        for neighbor in adjacency[node] ?? [] where !visited.contains(neighbor) {
            queue.append(neighbor)
        }
    }
    return order
}
