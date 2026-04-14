# Run the TravelPlanner benchmark.
#
# Usage:
#   mix run scripts/run.exs -- --split val --limit 5
#   mix run scripts/run.exs -- --split val --limit 1 --offset 0 --output results/val-run1

argv =
  case System.argv() do
    ["--" | rest] -> rest
    other -> other
  end

TravelPlanner.Runner.main(argv)
