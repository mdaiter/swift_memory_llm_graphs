import Foundation

struct NodeDescriptor: Codable, Equatable {
    let id: String
    let inputs: [String]
    let outputs: [String]
    let cost: Double?
    let latencyMs: Int?
}

final class NodeRegistry {
    private var nodes: [String: DomainNode] = [:]
    private var descriptors: [String: NodeDescriptor] = [:]

    func register(_ node: DomainNode, cost: Double? = nil, latencyMs: Int? = nil) {
        nodes[node.id] = node
        descriptors[node.id] = NodeDescriptor(
            id: node.id,
            inputs: node.inputRequirements.map { $0.name },
            outputs: node.outputKeys.map { $0.name },
            cost: cost,
            latencyMs: latencyMs
        )
    }

    func resolve(_ id: String) throws -> DomainNode {
        guard let node = nodes[id] else {
            throw GraphBuilderError.missingRequiredInput(node: id, key: "node_not_registered")
        }
        return node
    }

    func catalog() -> [NodeDescriptor] {
        Array(descriptors.values)
    }
}
