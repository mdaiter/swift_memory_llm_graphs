func renderAsciiPath(from path: [String]) -> String {
    guard !path.isEmpty else { return "START -> END" }
    let full = ["START"] + path + ["END"]
    return full.joined(separator: " -> ")
}
