enum TaskPriority: String, Codable, Equatable, StateValue {
    case high
    case medium
    case low
}

struct Task: Codable, Equatable, StateValue {
    let id: String
    let title: String
    let details: String
    let source: String
    let dueDate: String?
    let priority: TaskPriority
}
