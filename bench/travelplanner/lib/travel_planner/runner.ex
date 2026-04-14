defmodule TravelPlanner.Runner do
  @moduledoc """
  CLI entrypoint for running the TravelPlanner benchmark.

  Iterates over tasks from a dataset split, runs each through
  `TravelPlanner.run_task/2`, scores with `TravelPlanner.Evaluator.score_plan/3`,
  and writes results to JSONL + summary JSON via `TravelPlanner.ResultStore`.

  ## Usage

      mix run scripts/run.exs -- --split val --limit 5 --offset 0 --output results/val-run1
  """

  alias TravelPlanner.{Dataset, Evaluator, ReferenceInfo, ResultStore}

  @max_retries 3
  @initial_backoff_ms 2_000

  @doc """
  Main CLI entrypoint. Parses argv, loads dataset, runs tasks, writes results.
  """
  @spec main([String.t()]) :: :ok
  def main(argv) do
    case parse_opts(argv) do
      {:ok, opts} ->
        run(opts)

      {:error, message} ->
        IO.puts(:stderr, "Error: #{message}")
        IO.puts(:stderr, usage())
    end
  end

  @doc """
  Parse CLI arguments into an options map.

  Returns `{:ok, opts}` or `{:error, reason}`.
  """
  @spec parse_opts([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_opts(argv) do
    {parsed, _rest, invalid} =
      OptionParser.parse(argv,
        strict: [split: :string, limit: :integer, offset: :integer, output: :string],
        aliases: [s: :split, l: :limit, o: :output]
      )

    if invalid != [] do
      bad = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      {:error, "unknown options: #{bad}"}
    else
      with {:ok, split} <- parse_split(Keyword.get(parsed, :split)) do
        limit = Keyword.get(parsed, :limit)
        offset = Keyword.get(parsed, :offset, 0)
        output = Keyword.get(parsed, :output) || default_output_dir(split)

        {:ok, %{split: split, limit: limit, offset: offset, output: output}}
      end
    end
  end

  defp parse_split(nil), do: {:error, "--split is required (train, val, or test)"}
  defp parse_split("train"), do: {:ok, :train}
  defp parse_split("val"), do: {:ok, :validation}
  defp parse_split("validation"), do: {:ok, :validation}
  defp parse_split("test"), do: {:ok, :test}
  defp parse_split(other), do: {:error, "unknown split: #{inspect(other)}"}

  defp default_output_dir(split) do
    ts = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    "results/#{split_label(split)}-#{ts}"
  end

  defp split_label(:train), do: "train"
  defp split_label(:validation), do: "val"
  defp split_label(:test), do: "test"

  defp usage do
    """
    Usage: mix run scripts/run.exs -- --split <train|val|test> [options]

    Options:
      --split, -s    Dataset split (required): train, val, test
      --limit, -l    Max tasks to run (default: all)
      --offset       Skip this many tasks (default: 0)
      --output, -o   Output directory (default: results/<split>-<timestamp>/)
    """
  end

  # ─── run ──────────────────────────────────────────────────────────────────

  defp run(opts) do
    %{split: split, limit: limit, offset: offset, output: output} = opts

    IO.puts(:stderr, "Loading split=#{split} ...")
    tasks = Dataset.load(split)

    tasks =
      tasks
      |> Enum.drop(offset)
      |> then(fn t -> if limit, do: Enum.take(t, limit), else: t end)

    total = length(tasks)
    IO.puts(:stderr, "Running #{total} tasks (offset=#{offset}) ...")

    paths = ResultStore.init(output)
    run_start = System.monotonic_time(:millisecond)

    results =
      tasks
      |> Enum.with_index()
      |> Enum.map(fn {task, position} ->
        run_single_task(task, position, total, split, paths.jsonl)
      end)

    elapsed_total_ms = System.monotonic_time(:millisecond) - run_start
    ResultStore.write_summary(paths.summary, split, results, elapsed_total_ms)

    print_summary(split, results, output, elapsed_total_ms)
  end

  defp run_single_task(task, position, total, split, jsonl_path) do
    progress = "[#{position + 1}/#{total}]"
    start_ms = System.monotonic_time(:millisecond)

    result =
      try do
        db = ReferenceInfo.parse(task.reference_information)

        case run_with_retry(task, @max_retries, @initial_backoff_ms) do
          {:ok, plan} ->
            elapsed_ms = System.monotonic_time(:millisecond) - start_ms

            case Evaluator.score_plan(plan, task, db) do
              {:pass, details} ->
                serializable_details = serialize_constraint_details(details)
                result = ResultStore.pass_result(task.idx, split, plan, serializable_details, elapsed_ms)
                IO.puts(:stderr, "#{progress} Task ##{task.idx}: PASS (#{format_seconds(elapsed_ms)})")
                result

              {:fail, constraint, reason} ->
                result = ResultStore.fail_result(task.idx, split, plan, constraint, reason, elapsed_ms)

                IO.puts(
                  :stderr,
                  "#{progress} Task ##{task.idx}: FAIL #{constraint} - #{reason} (#{format_seconds(elapsed_ms)})"
                )

                result
            end

          {:error, stage, reason} ->
            elapsed_ms = System.monotonic_time(:millisecond) - start_ms
            reason_str = format_reason(reason)
            result = ResultStore.error_result(task.idx, split, stage, reason_str, elapsed_ms)

            IO.puts(
              :stderr,
              "#{progress} Task ##{task.idx}: ERROR at #{stage} - #{reason_str} (#{format_seconds(elapsed_ms)})"
            )

            result
        end
      rescue
        e ->
          elapsed_ms = System.monotonic_time(:millisecond) - start_ms
          reason_str = Exception.message(e)
          result = ResultStore.error_result(task.idx, split, :exception, reason_str, elapsed_ms)

          IO.puts(
            :stderr,
            "#{progress} Task ##{task.idx}: ERROR exception - #{reason_str} (#{format_seconds(elapsed_ms)})"
          )

          result
      end

    ResultStore.append_result(jsonl_path, result)
    result
  end

  defp run_with_retry(task, retries_left, backoff_ms) do
    case TravelPlanner.run_task(task) do
      {:ok, plan} ->
        {:ok, plan}

      {:error, _stage, reason} = error ->
        if retries_left > 0 and rate_limited?(reason) do
          IO.puts(:stderr, "  Rate limited, retrying in #{backoff_ms}ms ...")
          Process.sleep(backoff_ms)
          run_with_retry(task, retries_left - 1, backoff_ms * 2)
        else
          error
        end
    end
  end

  defp rate_limited?(reason) do
    reason_str = format_reason(reason)
    lower = String.downcase(reason_str)
    String.contains?(lower, "429") or String.contains?(lower, "rate")
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason, limit: 200)

  defp format_seconds(ms) do
    seconds = ms / 1000
    :erlang.float_to_binary(seconds, decimals: 1) <> "s"
  end

  defp serialize_constraint_details(details) when is_map(details) do
    details
    |> Map.update(:commonsense, [], &serialize_constraint_list/1)
    |> Map.update(:hard, [], &serialize_constraint_list/1)
  end

  defp serialize_constraint_list(list) when is_list(list) do
    Enum.map(list, fn
      :ok -> "ok"
      {:fail, reason} -> %{fail: reason}
      other -> inspect(other)
    end)
  end

  defp print_summary(split, results, output, elapsed_total_ms) do
    total = length(results)
    pass_count = Enum.count(results, &(&1.status == "pass"))
    fail_count = Enum.count(results, &(&1.status == "fail"))
    error_count = Enum.count(results, &(&1.status == "error"))
    pass_rate = if total > 0, do: Float.round(pass_count / total * 100, 1), else: 0.0

    IO.puts(:stderr, "")
    IO.puts(:stderr, "=== TravelPlanner Results ===")

    IO.puts(
      :stderr,
      "Split: #{split} | Tasks: #{total} | Pass: #{pass_count} | Fail: #{fail_count} | Error: #{error_count}"
    )

    IO.puts(:stderr, "Pass rate: #{pass_rate}%")
    IO.puts(:stderr, "Output: #{output}/")
    IO.puts(:stderr, "Elapsed: #{format_seconds(elapsed_total_ms)}")
  end
end
