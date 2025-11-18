# Reflective Life Assistant (Swift)

This refactor turns the trip-planning/email prototype into a plugin-ready, reflection-driven action framework.

## Core Concepts
- **DomainNode**: Pluggable units of work. Implement `id`, declare `inputRequirements`/`outputKeys`, and write `execute(state:context:)`.
- **Typed State**: `LifeState` wraps `TypedState` using `StateKey<T>`/`StateValue` for type-checked access while remaining extensible.
- **Reflection**: `ReflectionCriteria` + `HierarchicalReflector` provide declarative success/failure checks across strategic/tactical/execution layers.
- **Graph Builder**: `GraphConfig` + `GraphBuilder` construct executable graphs from configuration (nodes, edges, reflection points, entry node).

## Running the Demo
```
OPENAI_API_KEY=sk-... swift run ReflectiveLifeAssistant
```
The demo:
1. Loads emails, infers tone, scans files/calendar/finances.
2. Plans a Mexico 30th-birthday trip and drafts replies.
3. Analyzes a job offer (example of a third domain).
4. Reflects, refines, and produces a life audit summary.

## Adding a New Domain
1. Implement a node:
```swift
struct FinancialProjectionNode: DomainNode {
    let id = "financial_projection"
    let inputRequirements: [AnyStateKey] = [userRequestKey.erased]
    let outputKeys: [AnyStateKey] = [StateKey<String>("projection").erased]

    func execute(state: LifeState, context: ExecutionContext) async throws -> [String: Any] {
        let prompt = "Project monthly cash flow for: \(state[userRequestKey] ?? "")"
        let summary = try await context.llm.complete(prompt: prompt)
        return ["projection": summary]
    }
}
```
2. Add it to a `GraphConfig`’s `nodes`.
3. Wire it with an `Edge` (linear or keyed) to place it in the flow.
4. Provide `ReflectionCriteria` if it needs validation or retry policy.

## Examples Included
- **TripPlanningNode** and **EmailDraftingNode**: legacy domains refactored into plugins.
- **JobOfferAnalysisNode**: sample third domain showing how to add new capabilities without touching the core framework.
- **LLMEvaluationGenerator**: meta-layer that can derive `ReflectionCriteria` from a task description using an LLM.
- **GraphQueryBuilder**: LLM-driven graph synthesis from a user task + registered nodes; supports template selection and learning from prior executions.
- **LearningGraphBuilder**: prompts with past execution history to generate improved graphs.

## Reflection Layers
- `ReflectionLevel.strategic`: Are we solving the right problem?
- `ReflectionLevel.tactical`: Is the current approach viable?
- `ReflectionLevel.execution`: Is the output good enough?
Each level returns a `ReflectionResult` (`success`, `refine`, `escalate`, `requestUserInput`) that drives routing via `next_node`.

## Key Types
- `StateKey<T>` / `StateValue`: Typed access for state.
- `GraphConfig`: Declarative graph definition (nodes, edges, reflection points, entry).
- `ExecutionContext`: Shared services (LLM, calendar, filesystem, finance, message store, evaluation generator).

## Notes
- Trip/email behavior remains as examples; new domains are added by implementing `DomainNode` only.
- Routing is data-driven via `Edge.keyed` and reflection-driven `next_node` decisions.
