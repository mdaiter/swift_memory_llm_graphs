import Foundation

extension GraphMutation: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .inject(after, nodes, reason):
            let names = nodes.map { $0.id }.joined(separator: ", ")
            return "Injected nodes after \(after): [\(names)] (\(reason))"
        case let .prune(nodes, reason):
            return "Pruned nodes \(nodes) (\(reason))"
        case let .reroute(from, to, reason):
            return "Rerouted from \(from) to \(to) (\(reason))"
        case .none:
            return "No mutation"
        }
    }
}
