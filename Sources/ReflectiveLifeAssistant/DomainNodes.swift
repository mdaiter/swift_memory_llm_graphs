import Foundation

struct LoadMessagesNode: DomainNode {
    let id = "load_messages"
    let inputRequirements: [AnyStateKey] = [userRequestKey.erased]
    let outputKeys: [AnyStateKey] = [selectedMessagesKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let tokens = state.userRequest
            .lowercased()
            .split(separator: " ")
            .map(String.init)
        let matches = context.messageStore.importantUnreadMatching(keywords: tokens.isEmpty ? ["trip", "email"] : tokens)
        return [selectedMessagesKey.name: matches]
    }
}

struct InferStyleNode: DomainNode {
    let id = "infer_style"
    let inputRequirements: [AnyStateKey] = [selectedMessagesKey.erased]
    let outputKeys: [AnyStateKey] = [styleSummaryKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let samples = (state[selectedMessagesKey] ?? []).prefix(3).map { "\($0.subject): \($0.body)" }.joined(separator: "\n")
        let prompt = """
        Analyze these emails and describe the user's writing style in 1-2 sentences.
        Messages:
        \(samples)
        """
        let style = try await context.llm.complete(prompt: prompt)
        print("🧠 Inferred user style: \(style)")
        return [styleSummaryKey.name: style]
    }
}

struct ScanFilesNode: DomainNode {
    let id = "scan_files"
    let inputRequirements: [AnyStateKey] = []
    let outputKeys: [AnyStateKey] = [fileOverviewKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let files = try await context.fileSystem.listDocuments()
        let totalBytes = files.reduce(0) { $0 + $1.sizeBytes }
        let totalMB = Double(totalBytes) / 1_000_000.0
        let counts = Dictionary(grouping: files, by: { $0.kind.lowercased() }).mapValues { $0.count }
        let pdfs = counts["pdf", default: 0]
        let images = counts["image", default: 0]
        let others = files.count - pdfs - images
        let summary = "You have \(files.count) docs (~\(Int(totalMB.rounded())) MB). \(pdfs) PDFs, \(images) images, \(others) other."
        return [fileOverviewKey.name: summary]
    }
}

struct ScanCalendarNode: DomainNode {
    let id = "scan_calendar"
    let windowEnd: Date
    let inputRequirements: [AnyStateKey] = []
    let outputKeys: [AnyStateKey] = [calendarOverviewKey.erased]

    init(now: Date) {
        self.windowEnd = now.addingTimeInterval(14 * 24 * 3600)
    }

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let events = try await context.calendar.upcomingEvents(until: windowEnd)
        let flightCount = events.filter { $0.title.lowercased().contains("flight") }.count
        let hotelCount = events.filter { $0.title.lowercased().contains("hotel") }.count
        let summary = "Next 2 weeks: \(events.count) events; \(flightCount) look(s) like flight, \(hotelCount) look(s) like hotel booking."
        return [calendarOverviewKey.name: summary]
    }
}

struct ScanFinancesNode: DomainNode {
    let id = "scan_finances"
    let inputRequirements: [AnyStateKey] = []
    let outputKeys: [AnyStateKey] = [financeOverviewKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let txns = try await context.finance.recentTransactions(days: 30)
        let total = txns.reduce(0.0) { $0 + $1.amount }
        let travel = txns.filter { $0.category.lowercased() == "travel" }.reduce(0.0) { $0 + $1.amount }
        let formatter: (Double) -> String = { amount in
            String(format: "$%.0f", amount)
        }
        let summary = "Last 30 days: \(formatter(total)) total, \(formatter(travel)) on travel."
        return [financeOverviewKey.name: summary]
    }
}

struct ExtractTasksNode: DomainNode {
    let id = "extract_tasks"
    let inputRequirements: [AnyStateKey] = [selectedMessagesKey.erased]
    let outputKeys: [AnyStateKey] = [extractedTasksKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let messages = state[selectedMessagesKey] ?? []
        let messageText = messages.map { "\($0.subject): \($0.body)" }.joined(separator: "\n")
        let prompt = """
        You are helping extract actionable tasks. Given these messages, identify any clear tasks the user should do.
        Return them as a numbered list of short items.
        Messages:
        \(messageText)
        """
        let response = try await context.llm.complete(prompt: prompt)
        let lines = response
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let tasks: [Task] = lines.enumerated().map { idx, line in
            let cleaned = line.replacingOccurrences(of: #"^\d+\.\s*"#, with: "", options: .regularExpression)
            return Task(id: "task-\(idx)", title: cleaned, details: cleaned, source: "email", dueDate: nil, priority: .medium)
        }
        return [extractedTasksKey.name: tasks]
    }
}

struct PrioritizeTasksNode: DomainNode {
    let id = "prioritize_tasks"
    let inputRequirements: [AnyStateKey] = [extractedTasksKey.erased]
    let outputKeys: [AnyStateKey] = [prioritizedTasksKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let tasks = state[extractedTasksKey] ?? []
        let score: (Task) -> TaskPriority = { task in
            let text = (task.title + " " + task.details).lowercased()
            if ["today", "tomorrow", "asap", "invoice"].contains(where: { text.contains($0) }) {
                return .high
            }
            if ["next week", "soon"].contains(where: { text.contains($0) }) {
                return .medium
            }
            return .low
        }
        let prioritized = tasks.map { task in
            Task(id: task.id, title: task.title, details: task.details, source: task.source, dueDate: task.dueDate, priority: score(task))
        }.sorted { lhs, rhs in
            let order: [TaskPriority: Int] = [.high: 0, .medium: 1, .low: 2]
            return order[lhs.priority, default: 2] < order[rhs.priority, default: 2]
        }
        return [prioritizedTasksKey.name: prioritized]
    }
}

struct TripPlanningNode: DomainNode {
    let id = "plan_trip"
    let inputRequirements: [AnyStateKey] = [userRequestKey.erased]
    let outputKeys: [AnyStateKey] = [tripPlanKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        print("🧳 Planning a Mexico 30th birthday trip...")
        let prompt = """
        User request: \(state.userRequest)
        User style: \(state[styleSummaryKey] ?? "concise and friendly")
        Create a JSON-like single-paragraph description of a Mexico 30th birthday trip plan.
        """
        let planText = try await context.llm.complete(prompt: prompt)
        return [tripPlanKey.name: TripPlan(summary: planText)]
    }
}

struct EmailDraftingNode: DomainNode {
    let id = "draft_email"
    let inputRequirements: [AnyStateKey] = [selectedMessagesKey.erased]
    let outputKeys: [AnyStateKey] = [draftedRepliesKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        print("📧 Drafting replies in user style...")
        var replies = state[draftedRepliesKey] ?? []
        let summary = state[tripPlanKey]?.summary ?? ""
        for message in state[selectedMessagesKey] ?? [] {
            let prompt = """
            Write a concise, polite reply in the user's style to this email.
            Email: \(message.subject) - \(message.body)
            User style: \(state[styleSummaryKey] ?? "concise and friendly")
            Trip: \(summary)
            Reference the Mexico trip where appropriate.
            """
            let reply = try await context.llm.complete(prompt: prompt)
            replies.append(reply)
        }
        return [draftedRepliesKey.name: replies]
    }
}

struct GenerateActionPlanNode: DomainNode {
    let id = "generate_action_plan"
    let inputRequirements: [AnyStateKey] = [tripPlanKey.erased, prioritizedTasksKey.erased, userRequestKey.erased]
    let outputKeys: [AnyStateKey] = [actionPlanSummaryKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let tripSummary = state[tripPlanKey]?.summary ?? "no trip plan"
        let taskLines = (state[prioritizedTasksKey] ?? []).map { "[\($0.priority.rawValue.uppercased())] \($0.title)" }.joined(separator: "\n")
        let prompt = """
        You are summarizing what the user needs to do before their Mexico 30th-birthday trip.
        User request: \(state.userRequest)
        Trip plan: \(tripSummary)
        Prioritized tasks:
        \(taskLines)
        Return a short, 3–5 bullet 'What you must do before your trip' plan in the user's tone.
        """
        let summary = try await context.llm.complete(prompt: prompt)
        return [actionPlanSummaryKey.name: summary]
    }
}

struct GenerateLifeAuditNode: DomainNode {
    let id = "generate_life_audit"
    let inputRequirements: [AnyStateKey] = []
    let outputKeys: [AnyStateKey] = [actionPlanSummaryKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let userRequest = state.userRequest
        let files = state[fileOverviewKey] ?? "No file data"
        let calendar = state[calendarOverviewKey] ?? "No calendar data"
        let finance = state[financeOverviewKey] ?? "No finance data"
        let tripSummary = state[tripPlanKey]?.summary ?? "No trip plan"
        let repliesCount = state[draftedRepliesKey]?.count ?? 0
        let jobSummary = state[jobOfferAnalysisKey]?.recommendation ?? "No job offer analysis"
        let prompt = """
        You are a life-organizing assistant. The user asked: \(userRequest).
        Here is a high-level audit of their digital life before a Mexico trip:
        Files: \(files)
        Calendar: \(calendar)
        Finances: \(finance)
        Trip plan: \(tripSummary)
        Email replies drafted: \(repliesCount).
        Job offer analysis: \(jobSummary)
        In 4–7 bullet points, explain what is going on and what the user should focus on.
        """
        let summary = try await context.llm.complete(prompt: prompt)
        return [actionPlanSummaryKey.name: summary]
    }
}

struct ReflectionNode: DomainNode {
    let id = "reflect"
    let reflector: HierarchicalReflector
    let defaultNext: String
    let inputRequirements: [AnyStateKey] = []
    let outputKeys: [AnyStateKey] = [
        reflectionActionKey.erased,
        reflectionReasonKey.erased,
        reflectionCountKey.erased,
        nextNodeKey.erased
    ]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let currentCount = (state[reflectionCountKey] ?? 0) + 1
        var action = await reflector.reflect(state: state)
        if currentCount >= (reflector.levels[action.level]?.maxRetries ?? 3), case .refine = action.result {
            action = ReflectionAction(result: .success, level: action.level)
        }
        var updates: [String: Any] = [
            reflectionLevelKey.name: action.level.rawValue,
            reflectionCountKey.name: currentCount
        ]

        switch action.result {
        case .success:
            updates[reflectionActionKey.name] = "success"
            updates[nextNodeKey.name] = defaultNext
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

struct JobOfferAnalysisNode: DomainNode {
    let id = "job_offer_analysis"
    let inputRequirements: [AnyStateKey] = [userRequestKey.erased]
    let outputKeys: [AnyStateKey] = [jobOfferAnalysisKey.erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let prompt = """
        You are evaluating a job offer or career opportunity described by the user.
        Task: \(state.userRequest)

        Summarize highlights, risks, and provide a recommendation in 3 sentences.
        """
        let response = try await context.llm.complete(prompt: prompt)
        let parts = response
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let highlights = parts.first ?? "No highlights found"
        let risks = parts.dropFirst().first ?? "No risks found"
        let recommendation = parts.dropFirst(2).first ?? "Recommendation unavailable"
        let analysis = JobOfferAnalysis(
            highlights: String(highlights),
            risks: String(risks),
            recommendation: String(recommendation)
        )
        return [jobOfferAnalysisKey.name: analysis]
    }
}
