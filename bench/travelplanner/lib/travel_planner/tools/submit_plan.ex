defmodule TravelPlanner.Tools.SubmitPlan do
  @moduledoc "Termination tool: submit the final day-by-day travel plan."

  use Jido.Action,
    name: "submit_plan",
    description: "Submit the final day-by-day travel plan. Call this exactly once when your plan is complete.",
    schema: [
      plan: [
        type: {:list, :map},
        required: true,
        doc: "Array of day entries; length must equal task.days. See system prompt for required keys."
      ]
    ]

  alias Jido.Composer.Context

  @required_keys ~w(days current_city transportation breakfast attraction lunch dinner accommodation)
  @required_atoms ~w(days current_city transportation breakfast attraction lunch dinner accommodation)a

  @impl true
  def on_before_validate_params(params) do
    case Map.get(params, :plan) do
      list when is_list(list) ->
        {:ok, Map.put(params, :plan, Enum.map(list, &atomize_known_keys/1))}

      _ ->
        {:ok, params}
    end
  end

  @impl true
  def run(%{plan: plan} = params, _ctx) when is_list(plan) do
    task = fetch_task!(params)
    normalized = Enum.map(plan, &stringify_keys/1)

    with :ok <- validate_length(normalized, task),
         :ok <- validate_required_keys(normalized),
         :ok <- validate_days(normalized) do
      {:ok, %{plan: normalized}}
    end
  end

  def run(%{plan: plan}, _ctx), do: {:error, "plan must be a list of maps, got: #{inspect(plan, limit: 3)}"}

  defp atomize_known_keys(entry) when is_map(entry) do
    Map.new(entry, fn
      {k, v} when is_binary(k) ->
        atom = try do String.to_existing_atom(k) rescue ArgumentError -> nil end
        if atom in @required_atoms, do: {atom, v}, else: {k, v}
      {k, v} ->
        {k, v}
    end)
  end

  defp atomize_known_keys(other), do: other

  defp fetch_task!(params) do
    ambient = Map.get(params, Context.ambient_key(), %{})

    case Map.get(ambient, :task) do
      nil -> raise "missing :task in ambient context"
      task -> task
    end
  end

  defp stringify_keys(m) when is_map(m) do
    Map.new(m, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_keys(other), do: other

  defp validate_length(plan, %{days: days}) when is_integer(days) do
    case length(plan) do
      ^days -> :ok
      got -> {:error, "plan must have #{days} entries, got #{got}"}
    end
  end

  defp validate_required_keys(plan) do
    plan
    |> Enum.with_index(1)
    |> Enum.find_value(:ok, fn {entry, idx} ->
      missing = @required_keys -- Map.keys(entry)

      case missing do
        [] -> nil
        _ -> {:error, "entry #{idx} missing keys: #{inspect(missing)}"}
      end
    end)
  end

  defp validate_days(plan) do
    plan
    |> Enum.with_index(1)
    |> Enum.find_value(:ok, fn {entry, idx} ->
      day_val = Map.get(entry, "days")
      int_val = if is_binary(day_val), do: String.to_integer(day_val), else: day_val

      case int_val do
        ^idx -> nil
        other -> {:error, "entry #{idx} has days=#{inspect(other)}, expected #{idx}"}
      end
    end)
  end
end
