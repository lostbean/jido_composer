# Inspect one row of a TravelPlanner split.
#
# Usage:
#   mix run scripts/inspect_row.exs
#   mix run scripts/inspect_row.exs -- --split validation --idx 0
#   mix run scripts/inspect_row.exs -- --split train --idx 5

# When invoked as `mix run scripts/inspect_row.exs -- --split validation`,
# mix preserves the `--` separator in argv. Strip a single leading `--` so
# OptionParser doesn't treat it as the parse terminator.
argv =
  case System.argv() do
    ["--" | rest] -> rest
    other -> other
  end

{opts, _rest, _invalid} =
  OptionParser.parse(argv,
    strict: [split: :string, idx: :integer],
    aliases: [s: :split, i: :idx]
  )

split =
  case Keyword.get(opts, :split, "validation") do
    "train" -> :train
    "validation" -> :validation
    "test" -> :test
    other -> raise "unknown split #{inspect(other)}"
  end

idx = Keyword.get(opts, :idx, 0)

IO.puts("Loading split=#{split} ...")
tasks = TravelPlanner.Dataset.load(split)
IO.puts("Loaded #{length(tasks)} tasks.")

unless idx < length(tasks) do
  raise "idx #{idx} out of range (0..#{length(tasks) - 1})"
end

task = Enum.at(tasks, idx)

# ─── helpers ────────────────────────────────────────────────────────────────

trunc_str = fn
  nil, _ ->
    "<nil>"

  s, n when is_binary(s) ->
    if String.length(s) > n, do: String.slice(s, 0, n) <> "...<truncated>", else: s

  other, _ ->
    inspect(other)
end

type_label = fn
  v when is_list(v) -> "list"
  v when is_map(v) -> "map"
  v when is_binary(v) -> "string"
  v when is_integer(v) -> "integer"
  v when is_float(v) -> "float"
  v when is_boolean(v) -> "boolean"
  nil -> "nil"
  v -> "#{inspect(v.__struct__ || :unknown)}"
end

size_label = fn
  v when is_list(v) -> "len=#{length(v)}"
  v when is_map(v) -> "size=#{map_size(v)}"
  v when is_binary(v) -> "bytes=#{byte_size(v)}"
  _ -> ""
end

# ─── dump CSV-origin fields ─────────────────────────────────────────────────

IO.puts("\n========== TASK idx=#{task.idx} split=#{task.split} ==========")
IO.puts("org              : #{inspect(task.org)}")
IO.puts("dest             : #{inspect(task.dest)}")
IO.puts("days             : #{inspect(task.days)}")
IO.puts("date             : #{inspect(task.date)}")
IO.puts("level            : #{inspect(task.level)}")
IO.puts("people_number    : #{inspect(task.people_number)}")
IO.puts("budget           : #{inspect(task.budget)}")
IO.puts("local_constraint : #{inspect(task.local_constraint)}")
IO.puts("query            : #{trunc_str.(task.query, 400)}")

IO.puts("\nannotated_plan (truncated to 200 chars):")
IO.puts("  #{trunc_str.(task.annotated_plan, 200)}")

# ─── inspect raw CSV reference_information column (if any) ──────────────────
# We re-read the row from the CSV directly so we can also report what the
# CSV column itself contains, distinct from the JSONL.

split_name =
  case task.split do
    :train -> "train"
    :validation -> "validation"
    :test -> "test"
  end

csv_path = Path.expand("../data/#{split_name}.csv", __DIR__)
df = Explorer.DataFrame.from_csv!(csv_path, infer_schema_length: 1000)
csv_cols = Explorer.DataFrame.names(df)
IO.puts("\nCSV columns           : #{inspect(csv_cols)}")

raw_ref =
  if "reference_information" in csv_cols do
    df["reference_information"]
    |> Explorer.Series.to_list()
    |> Enum.at(task.idx)
  end

IO.puts("CSV reference_information cell:")

case raw_ref do
  nil ->
    IO.puts("  <not present in CSV>")

  s when is_binary(s) ->
    IO.puts("  type=string bytes=#{byte_size(s)}")
    IO.puts("  preview: #{trunc_str.(s, 300)}")

  other ->
    IO.puts("  type=#{type_label.(other)} value=#{inspect(other, limit: :infinity, printable_limit: 300)}")
end

# ─── inspect ref_info top-level structure ───────────────────────────────────

ref = task.reference_information

IO.puts("\n========== reference_information (from JSONL) ==========")
IO.puts("type=#{type_label.(ref)} #{size_label.(ref)}")

case ref do
  m when is_map(m) ->
    IO.puts("top-level keys: #{inspect(Map.keys(m))}")

    for {k, v} <- m do
      IO.puts("\n--- key=#{inspect(k)} ---")
      IO.puts("  type=#{type_label.(v)} #{size_label.(v)}")

      cond do
        is_list(v) and v != [] ->
          first = hd(v)
          IO.puts("  first element type=#{type_label.(first)}")

          if is_map(first) do
            IO.puts("  first element keys=#{inspect(Map.keys(first))}")

            preview =
              first
              |> Enum.take(6)
              |> Map.new()

            IO.puts("  first element preview: #{inspect(preview, limit: :infinity, printable_limit: 200)}")
          else
            IO.puts("  first element preview: #{trunc_str.(inspect(first), 300)}")
          end

        is_map(v) ->
          IO.puts("  inner keys=#{inspect(Map.keys(v))}")
          IO.puts("  preview: #{trunc_str.(inspect(v), 300)}")

        is_binary(v) ->
          IO.puts("  preview: #{trunc_str.(v, 300)}")

        true ->
          IO.puts("  value: #{inspect(v)}")
      end
    end

  list when is_list(list) ->
    IO.puts("first element: #{trunc_str.(inspect(hd(list)), 300)}")

  other ->
    IO.puts("value: #{trunc_str.(inspect(other), 300)}")
end

IO.puts("\n========== END ==========")
