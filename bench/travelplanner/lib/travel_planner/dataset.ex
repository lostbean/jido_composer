defmodule TravelPlanner.Dataset do
  @moduledoc """
  Loader for the HuggingFace `osunlp/TravelPlanner` dataset.

  The upstream dataset is distributed as CSV (`<split>.csv`) plus a per-split
  JSONL file (`<split>_ref_info.jsonl`) holding the per-task reference DB
  (flights, restaurants, hotels, attractions, distances, cities). This module:

    1. Downloads both files into `bench/travelplanner/data/` (idempotent —
       skips if the file already exists).
    2. Parses the CSV with Explorer.
    3. Reads the JSONL line-by-line with Jason.
    4. Joins the two by row index (line N of the JSONL == row N of the CSV)
       and returns a list of `%TravelPlanner.Task{}` structs.

  The `:reference_information` field on each returned task is the
  JSON-decoded map (string keys preserved). Any `reference_information`
  column on the CSV is ignored in favor of the JSONL.

  ## Example

      iex> tasks = TravelPlanner.Dataset.load(:validation)
      iex> length(tasks)
      180
  """

  alias TravelPlanner.Task, as: TPTask

  @data_dir Path.expand("../../data", __DIR__)
  @base_url "https://huggingface.co/datasets/osunlp/TravelPlanner/resolve/main"

  @type split :: :train | :validation | :test

  @doc """
  Download the CSV and JSONL files for the given split into the local data dir.
  Skips files that already exist. Raises if a download fails.
  """
  @spec download(split()) :: :ok
  def download(split) when split in [:train, :validation, :test] do
    name = split_name(split)
    File.mkdir_p!(@data_dir)

    fetch!("#{@base_url}/#{name}.csv", Path.join(@data_dir, "#{name}.csv"))
    fetch!("#{@base_url}/#{name}_ref_info.jsonl", Path.join(@data_dir, "#{name}_ref_info.jsonl"))
    :ok
  end

  @doc """
  Load a split into a list of `%TravelPlanner.Task{}` structs in dataset
  order. Calls `download/1` first.
  """
  @spec load(split()) :: [TPTask.t()]
  def load(split) when split in [:train, :validation, :test] do
    :ok = download(split)
    name = split_name(split)
    csv_path = Path.join(@data_dir, "#{name}.csv")
    jsonl_path = Path.join(@data_dir, "#{name}_ref_info.jsonl")

    rows = read_csv_rows(csv_path)
    refs = read_jsonl(jsonl_path)

    if length(rows) != length(refs) do
      raise """
      Row count mismatch for #{split}: CSV has #{length(rows)} rows but \
      JSONL has #{length(refs)} entries. The two files must be aligned.
      """
    end

    rows
    |> Enum.zip(refs)
    |> Enum.with_index()
    |> Enum.map(fn {{row, ref}, idx} -> build_task(idx, split, row, ref) end)
  end

  # ─── internals ──────────────────────────────────────────────────────────

  defp split_name(:train), do: "train"
  defp split_name(:validation), do: "validation"
  defp split_name(:test), do: "test"

  defp fetch!(url, dest_path) do
    if File.exists?(dest_path) do
      :ok
    else
      tmp_path = dest_path <> ".part"

      case Req.get(url, into: File.stream!(tmp_path)) do
        {:ok, %{status: 200}} ->
          File.rename!(tmp_path, dest_path)
          :ok

        {:ok, %{status: status}} ->
          _ = File.rm(tmp_path)
          raise "failed to download #{url}: HTTP #{status}"

        {:error, reason} ->
          _ = File.rm(tmp_path)
          raise "failed to download #{url}: #{inspect(reason)}"
      end
    end
  end

  defp read_csv_rows(csv_path) do
    df = Explorer.DataFrame.from_csv!(csv_path, infer_schema_length: 1000)
    columns = Explorer.DataFrame.names(df)
    n = Explorer.DataFrame.n_rows(df)

    # Pre-extract each column to a list once.
    col_lists =
      Map.new(columns, fn col ->
        {col, Explorer.Series.to_list(df[col])}
      end)

    for i <- 0..(n - 1) do
      Map.new(columns, fn col -> {col, Enum.at(col_lists[col], i)} end)
    end
  end

  defp read_jsonl(jsonl_path) do
    jsonl_path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  defp build_task(idx, split, row, ref) do
    %TPTask{
      idx: idx,
      split: split,
      org: row["org"],
      dest: row["dest"],
      days: cast_int(row["days"]),
      date: row["date"],
      level: row["level"],
      query: row["query"],
      reference_information: ref,
      local_constraint: row["local_constraint"],
      people_number: cast_int(row["people_number"]),
      budget: row["budget"],
      annotated_plan: row["annotated_plan"]
    }
  end

  defp cast_int(nil), do: nil
  defp cast_int(n) when is_integer(n), do: n
  defp cast_int(n) when is_float(n), do: trunc(n)

  defp cast_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end
end
