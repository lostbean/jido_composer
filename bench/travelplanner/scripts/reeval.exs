# Re-evaluate plans from an existing results JSONL with current Evaluator + PostProcess.
#
# Usage:
#   mix run scripts/reeval.exs -- results/val-phase-a-v3
#   mix run scripts/reeval.exs -- results/val-phase-a-v3 --repost-process

argv =
  case System.argv() do
    ["--" | rest] -> rest
    other -> other
  end

{opts, [results_dir], _} =
  OptionParser.parse(argv, strict: [repost_process: :boolean])

repost_process = Keyword.get(opts, :repost_process, false)
jsonl_path = Path.join(results_dir, "results.jsonl")

unless File.exists?(jsonl_path) do
  IO.puts(:stderr, "File not found: #{jsonl_path}")
  System.halt(1)
end

IO.puts(:stderr, "Loading validation split for task data...")
tasks = TravelPlanner.Dataset.load(:validation)
tasks_by_idx = Map.new(tasks, &{&1.idx, &1})

IO.puts(:stderr, "Re-evaluating #{jsonl_path} (repost_process=#{repost_process})...")

results =
  jsonl_path
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.map(fn line ->
    result = Jason.decode!(line)
    idx = result["idx"]
    plan = result["plan"]
    status = result["status"]

    if status == "error" or plan == nil do
      %{idx: idx, status: :error, constraint: nil, reason: "original error"}
    else
      task = tasks_by_idx[idx]
      db = TravelPlanner.ReferenceInfo.parse(task.reference_information)

      plan =
        if repost_process do
          TravelPlanner.PostProcess.fix(plan, task, db)
        else
          plan
        end

      case TravelPlanner.Evaluator.score_plan(plan, task, db) do
        {:pass, _details} ->
          %{idx: idx, status: :pass, constraint: nil, reason: nil}

        {:fail, constraint, reason} ->
          %{idx: idx, status: :fail, constraint: constraint, reason: reason}
      end
    end
  end)

total = length(results)
pass = Enum.count(results, &(&1.status == :pass))
fail = Enum.count(results, &(&1.status == :fail))
error = Enum.count(results, &(&1.status == :error))

IO.puts(:stderr, "\n=== Re-evaluation Results ===")
IO.puts(:stderr, "Total: #{total} | Pass: #{pass} | Fail: #{fail} | Error: #{error}")
IO.puts(:stderr, "Pass rate: #{Float.round(pass / total * 100, 1)}%")

if fail > 0 do
  IO.puts(:stderr, "\nFailure breakdown:")

  results
  |> Enum.filter(&(&1.status == :fail))
  |> Enum.group_by(& &1.constraint)
  |> Enum.sort_by(fn {_, v} -> -length(v) end)
  |> Enum.each(fn {constraint, items} ->
    IO.puts(:stderr, "  #{length(items)} #{constraint}")
  end)

  IO.puts(:stderr, "\nDetailed failures:")

  results
  |> Enum.filter(&(&1.status == :fail))
  |> Enum.each(fn r ->
    reason_short = String.slice(r.reason || "", 0..100)
    IO.puts(:stderr, "  Task #{r.idx}: #{r.constraint} -- #{reason_short}")
  end)
end
