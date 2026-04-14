defmodule TravelPlanner.PlannerWorkflow do
  @moduledoc """
  Workflow FSM wrapping the two-stage gather -> assemble pipeline.

  States:
    * `:gather`   — runs GatherOrchestrator to produce a markdown summary
    * `:assemble` — runs AssembleOrchestrator to produce a validated day plan
    * `:done`     — terminal success
    * `:failed`   — terminal failure

  ## Data Flow

  The Workflow DSL scopes each node's output under its state name in the
  accumulated context. Orchestrators accessed via AgentNode read `query`
  from the top-level working context, which doesn't change between states.
  To thread the gather output as the assemble query, we use lightweight
  wrapper actions that call the orchestrators directly with the correct
  query and ambient context.

  ## Usage

      task = %TravelPlanner.Task{...}
      db = TravelPlanner.ReferenceInfo.parse(task.reference_information)
      agent = TravelPlanner.PlannerWorkflow.new()
      {:ok, result} = TravelPlanner.PlannerWorkflow.run_sync(agent, %{
        task: task,
        reference_db: db
      })
      plan = result[:assemble][:plan]
  """

  use Jido.Composer.Workflow,
    name: "travel_planner_pipeline",
    description: "Two-stage gather/assemble travel planning pipeline",
    nodes: %{
      gather: TravelPlanner.PlannerWorkflow.GatherAction,
      assemble: TravelPlanner.PlannerWorkflow.AssembleAction
    },
    transitions: %{
      {:gather, :ok} => :assemble,
      {:assemble, :ok} => :done,
      {:_, :error} => :failed
    },
    initial: :gather,
    ambient: [:task, :reference_db, :req_options]
end

defmodule TravelPlanner.PlannerWorkflow.GatherAction do
  @moduledoc false

  use Jido.Action,
    name: "planner_gather",
    description: "Wraps GatherOrchestrator: builds query, runs gather, returns summary.",
    schema: [
      task: [type: :map, required: true, doc: "TravelPlanner.Task struct"],
      reference_db: [type: :map, required: true, doc: "Parsed reference DB"]
    ]

  alias TravelPlanner.GatherOrchestrator

  @impl true
  def run(params, _context) do
    task = get_ambient(params, :task)
    db = get_ambient(params, :reference_db)
    req_options = get_ambient(params, :req_options)

    agent =
      GatherOrchestrator.new()
      |> maybe_configure(req_options)

    query = build_gather_query(task)
    ambient = %{reference_db: db, task: task}

    case GatherOrchestrator.query_sync(agent, query, ambient) do
      {:ok, _agent, result} when is_binary(result) and byte_size(result) > 0 ->
        {:ok, %{summary: result}}

      {:ok, _agent, result} ->
        {:error, {:no_final_message, result}}

      {:suspended, _agent, suspension} ->
        {:error, {:unexpected_suspension, suspension}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_ambient(params, key) do
    case Map.get(params, Jido.Composer.Context.ambient_key()) do
      nil -> nil
      ambient -> Map.get(ambient, key)
    end
  end

  defp maybe_configure(agent, nil), do: agent

  defp maybe_configure(agent, req_options) when is_list(req_options) do
    GatherOrchestrator.configure(agent, req_options: req_options)
  end

  defp maybe_configure(agent, _), do: agent

  defp build_gather_query(task) do
    """
    Origin: #{task.org}
    Destination: #{task.dest}
    Days: #{task.days}
    Date(s): #{inspect(task.date)}
    Level: #{task.level}

    User request: #{task.query}
    Budget: #{inspect(task.budget)}
    Local constraints: #{inspect(task.local_constraint)}
    People: #{inspect(task.people_number)}

    Gather the data needed to plan this trip and produce the markdown summary.
    """
  end
end

defmodule TravelPlanner.PlannerWorkflow.AssembleAction do
  @moduledoc false

  use Jido.Action,
    name: "planner_assemble",
    description: "Wraps AssembleOrchestrator: builds query from gather summary, runs assemble.",
    schema: [
      gather: [type: :map, required: false, doc: "Scoped output from gather state"]
    ]

  alias TravelPlanner.AssembleOrchestrator

  @impl true
  def run(params, _context) do
    task = get_ambient(params, :task)
    req_options = get_ambient(params, :req_options)
    gather_summary = get_in(params, [:gather, :summary]) || ""

    agent =
      AssembleOrchestrator.new()
      |> maybe_configure(req_options)

    query = build_assemble_query(task, gather_summary)
    ambient = %{task: task}

    case AssembleOrchestrator.query_sync(agent, query, ambient) do
      {:ok, _agent, %{plan: plan}} when is_list(plan) ->
        {:ok, %{plan: plan}}

      {:ok, _agent, result} ->
        {:error, {:bad_result_shape, result}}

      {:suspended, _agent, suspension} ->
        {:error, {:unexpected_suspension, suspension}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_ambient(params, key) do
    case Map.get(params, Jido.Composer.Context.ambient_key()) do
      nil -> nil
      ambient -> Map.get(ambient, key)
    end
  end

  defp maybe_configure(agent, nil), do: agent

  defp maybe_configure(agent, req_options) when is_list(req_options) do
    AssembleOrchestrator.configure(agent, req_options: req_options)
  end

  defp maybe_configure(agent, _), do: agent

  defp build_assemble_query(task, gather_summary) do
    """
    User request: #{task.query}
    Budget: #{inspect(task.budget)}
    Days: #{task.days}
    People: #{inspect(task.people_number)}
    Local constraints: #{inspect(task.local_constraint)}

    Pre-gathered data:

    #{gather_summary}

    Produce a plan with exactly #{task.days} day entries and call submit_plan.
    """
  end
end
