import Foundation

final class ASCIIGraphVisualizer {
    struct VisualNode {
        let id: String
        let displayName: String
        let confidence: Double?
        let isNew: Bool
        let hasWarning: Bool
    }

    struct Layout {
        let positions: [String: (x: Int, y: Int)]
        let maxY: Int
    }

    func visualize(config: GraphConfig, confidences: [String: Double] = [:], highlight: [String] = []) -> String {
        let nodes = config.nodes.map { node in
            let conf = confidences[node.id]
            return VisualNode(
                id: node.id,
                displayName: truncate(node.id, maxLength: 12),
                confidence: conf,
                isNew: highlight.contains(node.id),
                hasWarning: (conf ?? 1.0) < 0.6
            )
        }
        let layout = layoutNodes(nodes, edges: config.edges, entry: config.entryNode)
        var canvas: [[Character]] = Array(
            repeating: Array(repeating: " ", count: 80),
            count: layout.maxY + 10
        )

        for node in nodes {
            guard let pos = layout.positions[node.id] else { continue }
            drawNode(node, at: pos, on: &canvas)
        }
        for edge in config.edges {
            let targets = targetsForEdge(edge)
            for target in targets {
                if let from = layout.positions[sourceForEdge(edge)],
                   let to = layout.positions[target] {
                    drawEdge(from: from, to: to, on: &canvas)
                }
            }
        }
        return canvas.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
    }

    private func layoutNodes(_ nodes: [VisualNode], edges: [Edge], entry: String) -> Layout {
        var positions: [String: (x: Int, y: Int)] = [:]
        var layers: [[String]] = []
        var visited: Set<String> = []
        var queue: [String] = [entry]
        var layer = 0

        while !queue.isEmpty {
            let current = queue
            layers.append(current)
            visited.formUnion(current)
            var next: [String] = []
            for id in current {
                let children = edges
                    .filter { sourceForEdge($0) == id }
                    .flatMap { targetsForEdge($0) }
                    .filter { !visited.contains($0) }
                next.append(contentsOf: children)
            }
            queue = next
            layer += 1
            if layer > 20 { break }
        }

        for (yIndex, layerIds) in layers.enumerated() {
            let nodeWidth = 16
            let spacing = 4
            let totalWidth = layerIds.count * (nodeWidth + spacing) - spacing
            let startX = max(0, (80 - totalWidth) / 2)
            for (i, id) in layerIds.enumerated() {
                positions[id] = (x: startX + i * (nodeWidth + spacing), y: yIndex * 6)
            }
        }

        let maxY = (layers.count) * 6
        return Layout(positions: positions, maxY: maxY)
    }

    private func drawNode(_ node: VisualNode, at pos: (x: Int, y: Int), on canvas: inout [[Character]]) {
        let width = 14
        let lines = [
            "┌" + String(repeating: "─", count: width) + "┐",
            "│ " + node.displayName.padding(toLength: width - 2, withPad: " ", startingAt: 0) + " │",
            "└" + String(repeating: "─", count: width) + "┘"
        ]
        for (dy, line) in lines.enumerated() {
            for (dx, ch) in line.enumerated() {
                set(x: pos.x + dx, y: pos.y + dy, ch: ch, on: &canvas)
            }
        }
        if let conf = node.confidence {
            let label = String(format: " conf: %.1f", conf) + (node.hasWarning ? " ⚠️" : "")
            for (dx, ch) in label.enumerated() {
                set(x: pos.x + dx, y: pos.y + 3, ch: ch, on: &canvas)
            }
        }
        if node.isNew {
            let marker = "◀ NEW"
            for (dx, ch) in marker.enumerated() {
                set(x: pos.x + width + 2 + dx, y: pos.y + 1, ch: ch, on: &canvas)
            }
        }
    }

    private func drawEdge(from: (x: Int, y: Int), to: (x: Int, y: Int), on canvas: inout [[Character]]) {
        let fromCenter = (x: from.x + 7, y: from.y + 3)
        let toCenter = (x: to.x + 7, y: to.y)
        guard toCenter.y > fromCenter.y else { return }
        if fromCenter.x == toCenter.x {
            for y in (fromCenter.y + 1)...toCenter.y {
                set(x: fromCenter.x, y: y, ch: y == toCenter.y ? "▼" : "│", on: &canvas)
            }
        } else {
            // branch horizontally then down
            let y = fromCenter.y
            let range = fromCenter.x < toCenter.x ? (fromCenter.x + 1)...toCenter.x : (toCenter.x...fromCenter.x - 1)
            for x in range {
                set(x: x, y: y, ch: "─", on: &canvas)
            }
            set(x: toCenter.x, y: toCenter.y - 1, ch: "▼", on: &canvas)
            for yPos in (y + 1)..<toCenter.y {
                set(x: toCenter.x, y: yPos, ch: "│", on: &canvas)
            }
        }
    }

    private func set(x: Int, y: Int, ch: Character, on canvas: inout [[Character]]) {
        guard y >= 0 && y < canvas.count && x >= 0 && x < canvas[0].count else { return }
        canvas[y][x] = ch
    }

    private func truncate(_ text: String, maxLength: Int) -> String {
        if text.count <= maxLength { return text }
        let prefix = text.prefix(maxLength - 1)
        return prefix + "…"
    }

    private func targetsForEdge(_ edge: Edge) -> [String] {
        switch edge {
        case let .linear(_, to):
            return [to]
        case let .parallel(_, tos):
            return tos
        case let .keyed(_, _, mapping, fallback):
            return Array(mapping.values) + [fallback]
        case let .keyedDynamic(_, _, mapping, fallback):
            return Array(mapping.values) + [fallback]
        }
    }

    private func sourceForEdge(_ edge: Edge) -> String {
        switch edge {
        case let .linear(from, _): return from
        case let .parallel(from, _): return from
        case let .keyed(from, _, _, _): return from
        case let .keyedDynamic(from, _, _, _): return from
        }
    }
}
