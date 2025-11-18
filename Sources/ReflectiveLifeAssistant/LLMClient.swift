import Foundation
import LangChain
import AsyncHTTPClient
import OpenAIKit

protocol LLMClient {
    func complete(prompt: String) async throws -> String
}

enum LLMError: Error, Equatable {
    case missingAPIKey
    case noResponse
}

final class OpenAILLMClient: LLMClient {
    let apiKey: String
    private let model: ModelID
    private let httpClient: HTTPClient

    init(apiKey: String? = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], model: ModelID = Model.GPT3.gpt3_5Turbo) throws {
        guard let apiKey, !apiKey.isEmpty else {
            throw LLMError.missingAPIKey
        }
        self.apiKey = apiKey
        self.model = model
        self.httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        LC.initSet(["OPENAI_API_KEY": apiKey])
    }

    deinit {
        try? httpClient.syncShutdown()
    }

    func complete(prompt: String) async throws -> String {
        let llm = ChatOpenAI(httpClient: httpClient, temperature: 0.2, model: model)
        guard let result = await llm.generate(text: prompt) else {
            throw LLMError.noResponse
        }
        if result.stream && result.llm_output == nil {
            try await result.setOutput()
        }
        guard let text = result.llm_output?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw LLMError.noResponse
        }
        return text
    }
}

final class MockLLMClient: LLMClient {
    var lastPrompt: String?
    var response: String

    init(response: String) {
        self.response = response
    }

    func complete(prompt: String) async throws -> String {
        lastPrompt = prompt
        return response
    }
}

func summarizeRun(llm: LLMClient, state: LifeState) async throws -> String {
    let asciiPath = renderAsciiPath(from: state.actionPath)
    let tripSummary = state[tripPlanKey]?.summary ?? "no trip plan"
    let replies = state[draftedRepliesKey] ?? []
    let reflectionCount = state[reflectionCountKey] ?? 0

    let prompt = """
    You are summarizing what an AI assistant just did.

    Action path (nodes visited):
    \(asciiPath)

    Trip plan summary:
    \(tripSummary)

    Number of drafted replies: \(replies.count)
    Reflection iterations: \(reflectionCount)

    In 2–3 sentences, explain for the user what actions were taken on their behalf,
    in plain language, referencing both the trip planning and the email drafting.
    """

    return try await llm.complete(prompt: prompt)
}
