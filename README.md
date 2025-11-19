# ReflectiveLifeAssistant (Swift)

A pluggable, reflection-aware action graph framework. It lets you define domain nodes, wire them into declarative graphs, adapt execution at runtime (mutations, uncertainty routing), and evolve graphs from prior runs.

## Core Concepts

- **DomainNode**: Units of work with declared inputs/outputs. They run with an `ExecutionContext` (LLM, data clients, mutation hooks) and return state updates/ConfidentValue metadata.
- **Typed State**: `LifeState` uses typed `StateKey<T>`/`StateValue` accessors (including `ConfidentValue<T>` for uncertainty tracking).
- **GraphConfig & Builder**: Declarative graph definition (nodes, edges, reflection points, entry). `GraphBuilder` compiles it to an executable graph.
- **Adaptive Execution**: `AdaptiveExecutor` supports runtime mutations (inject/prune/reroute), pending node-requested mutations, and uncertainty-aware routing.
- **Uncertainty Routing**: `UncertaintyRouter` inspects confidences, can trigger mutations (e.g., gather more data) or ask for user input.
- **Graph Synthesis**: `GraphQueryBuilder`/`GraphEvolver` generate/adjust graphs via LLMs and past execution traces; salvage logic for malformed responses.
- **Execution Memory**: `ExecutionMemory` stores traces (task, path, outcomes) to inform future graph generation.
- **Visualization**: ASCII graph snapshots during mutations (see meeting prep demo).

## Structure

- `Domain.swift`: `DomainNode`, `ExecutionContext` (with mutation requests).
- `State.swift`: Typed state, keys, models, confidence tracking.
- `GraphBuilder.swift`: Compile `GraphConfig` to executable graph; supports linear/parallel/keyed edges.
- `AdaptiveExecutor.swift`: Executes graphs, applies mutations, integrates `UncertaintyRouter`, tracks action path.
- `UncertaintyRouter.swift`: Confidence-based routing decisions (inject, ask user, caveat, proceed).
- `GraphQueryBuilder.swift` & `ExecutionMemory.swift`: LLM-driven graph generation, learning from past traces, fallback graph salvage.
- `ASCIIGraphVisualizer.swift`: Box-drawing graph rendering with highlights/warnings.
- `MeetingPrepDemo.swift`: Example graph showcasing mutations, uncertainty routing, ASCII snapshots, and final doc output (toggle with `MEETING_PREP_DEMO=1`).
- Other domain examples: trip planning, email drafting, job analysis.

## Running

- Default life assistant: `swift run ReflectiveLifeAssistant`
- Meeting prep demo (adaptive + visualization): `MEETING_PREP_DEMO=1 ADAPTIVE_EXECUTION=1 swift run ReflectiveLifeAssistant`
- Tests: `swift test` (run locally; sandboxed environments may block SwiftPM caches).

## Extending

- Add a node: implement `DomainNode`, declare input/output keys, return updates (and optional `context.requestMutation`).
- Add uncertainty logic: extend `UncertaintyRouter` rules or feed confidences via `ConfidentValue`.
- Persist learnings: record `ExecutionTrace` in `ExecutionMemory` and plug into `GraphEvolver`.
- Visualize: call `ASCIIGraphVisualizer.visualize(config:highlight:)` when graphs change.

## Highlights

- Pluggable nodes; graphs are declarative, not hardcoded flows.
- Runtime adaptation: graph mutations + uncertainty routing during execution.
- Typed, confidence-aware state.
- LLM-assisted graph synthesis with salvage fallback.
- Execution memory to evolve graphs over time.
- Built-in ASCII visualization for live graph evolution.
