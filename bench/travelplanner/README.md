# travel_planner_bench

Standalone Mix subproject that ports the
[OpenSymbolicAI TravelPlanner](https://huggingface.co/datasets/osunlp/TravelPlanner)
benchmark on top of `jido_composer`. Lives under `bench/travelplanner/` so it
can pull in heavy dependencies (Explorer/Polars, ReqLLM) without bloating the
parent library.

## Phases

The benchmark runs in two phases:

1. **Tool-use phase** — an agent answers a query by calling a fixed set of
   tools (flight/restaurant/hotel/attraction/distance lookups) backed by the
   per-task reference DB.
2. **Sole-planning phase** — given the same query plus the full reference DB
   inlined, the agent must produce a multi-day itinerary that satisfies hard
   constraints (budget, room rule, transportation, cuisine, room type, etc.).

Milestone 1 only sets up the dataset loader.

## Run

```sh
cd bench/travelplanner
mix deps.get
mix run scripts/inspect_row.exs -- --split validation --idx 0
```

The first run downloads `validation.csv` and `validation_ref_info.jsonl` from
HuggingFace into `data/` (a few MB; no auth required). Subsequent runs reuse
the cached files.

## Test

```sh
mix test --include network
```

The smoke test is tagged `:network` because it hits HuggingFace.
