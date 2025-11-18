struct Message: Codable, Equatable, StateValue {
    let id: String
    let from: String
    let subject: String
    let body: String
    let isUnread: Bool
    let isImportant: Bool
}

struct MessageStore {
    private let messages: [Message]

    init(messages: [Message]) {
        self.messages = messages
    }

    func importantUnreadMatching(keywords: [String]) -> [Message] {
        let loweredKeywords = keywords.map { $0.lowercased() }
        return messages.filter { message in
            guard message.isUnread && message.isImportant else { return false }
            let subject = message.subject.lowercased()
            let body = message.body.lowercased()
            return loweredKeywords.contains { kw in
                subject.contains(kw) || body.contains(kw)
            }
        }
    }
}
