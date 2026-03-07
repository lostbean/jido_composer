# Extracts Elixir code cells from a .livemd file and evaluates them as a single script.
#
# Usage:
#   mix run scripts/run_livemd.exs livebooks/01_etl_pipeline.livemd
#   mix run scripts/run_livemd.exs livebooks/*.livemd
#
# Skips cells that use Mix.install or blocking Kino widgets.
# Replaces Kino display calls with IO equivalents.

defmodule LivemdRunner do
  @skip_patterns [
    ~r/Mix\.install\(/,
    ~r/Kino\.Control\.stream/,
    ~r/Kino\.Frame\./,
    ~r/Kino\.render/
  ]

  def run(path) do
    unless File.exists?(path) do
      IO.puts(:stderr, "File not found: #{path}")
      System.halt(1)
    end

    IO.puts("\n#{String.duplicate("=", 60)}")
    IO.puts("Running: #{path}")
    IO.puts(String.duplicate("=", 60))

    cells = extract_cells(File.read!(path))
    total = length(cells)
    skipped = Enum.count(cells, &skip_cell?/1)

    # Concatenate all non-skipped cells into a single script.
    # This preserves aliases, variables, and module definitions across cells.
    script =
      cells
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {cell, idx} ->
        if skip_cell?(cell) do
          IO.puts("  [#{idx}/#{total}] Skipping (Mix.install/Kino UI)")
          []
        else
          IO.puts("  [#{idx}/#{total}] Including (#{line_count(cell)} lines)")
          [sanitize_kino(cell)]
        end
      end)
      |> Enum.join("\n\n")

    IO.puts("\nEvaluating #{total - skipped} cells...")

    result =
      try do
        Code.eval_string(script, [], file: path, line: 1)
        :ok
      rescue
        e ->
          IO.puts(:stderr, "\n  ERROR: #{Exception.format(:error, e, __STACKTRACE__)}")
          :error
      catch
        kind, value ->
          IO.puts(:stderr, "\n  ERROR: #{Exception.format(kind, value, __STACKTRACE__)}")
          :error
      end

    status = if result == :ok, do: "PASSED", else: "FAILED"
    IO.puts("\n#{String.duplicate("-", 40)}")
    IO.puts("#{status} (#{total - skipped} evaluated, #{skipped} skipped)")

    result
  end

  defp extract_cells(content) do
    # Match ```elixir ... ``` blocks but not ````elixir (4-backtick blocks)
    regex = ~r/(?<!`)```elixir\n(.*?)```/s

    Regex.scan(regex, content, capture: :all_but_first)
    |> Enum.map(fn [code] -> String.trim(code) end)
    |> Enum.reject(&(&1 == ""))
  end

  defp skip_cell?(cell) do
    Enum.any?(@skip_patterns, &Regex.match?(&1, cell))
  end

  defp line_count(cell) do
    cell |> String.split("\n") |> length()
  end

  defp sanitize_kino(cell) do
    cell
    |> String.replace(~r/Kino\.Markdown\.new\(/, "IO.puts(")
    |> String.replace(~r/Kino\.Tree\.new\(/, "IO.inspect(")
    |> String.replace(~r/Kino\.Layout\.grid\(/, "IO.inspect(")
    |> String.replace(~r/Kino\.Layout\.tabs\(/, "IO.inspect(")
  end
end

# --- Main ---

case System.argv() do
  [] ->
    IO.puts("Usage: mix run scripts/run_livemd.exs <file.livemd> [file2.livemd ...]")
    System.halt(1)

  paths ->
    results =
      paths
      |> Enum.flat_map(fn path ->
        case Path.wildcard(path) do
          [] -> [path]
          expanded -> expanded
        end
      end)
      |> Enum.sort()
      |> Enum.map(&LivemdRunner.run/1)

    failed = Enum.count(results, &(&1 == :error))

    if failed > 0 do
      IO.puts("\n#{failed} file(s) had failures.")
      System.halt(1)
    else
      IO.puts("\nAll files passed.")
    end
end
