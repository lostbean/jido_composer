defmodule TravelPlanner do
  @moduledoc """
  jido_composer port of the OpenSymbolicAI TravelPlanner benchmark.

  Entry points:
    * `TravelPlanner.Dataset.load/1` — load a split into `[%TravelPlanner.Task{}]`
    * `TravelPlanner.run_task/2` — run one task end-to-end through the gather and assemble stages
    * `TravelPlanner.Runner.main/1` — CLI entrypoint (M8)
  """

  alias TravelPlanner.AssembleOrchestrator
  alias TravelPlanner.GatherOrchestrator
  alias TravelPlanner.ReferenceInfo
  alias TravelPlanner.Task, as: TPTask

  @type stage :: :gather | :assemble | :shape
  @type plan :: [map()]

  @doc """
  Run one TravelPlanner task end-to-end.

  Pipes the task through the gather stage (free-form markdown summary) and the
  assemble stage (validated DayPlan list via `submit_plan`). Returns the plan
  as a list of string-keyed maps with `length(plan) == task.days`.

  ## Options

    * `:req_options` — keyword list threaded into both orchestrators via
      `configure/2` (e.g. `[plug: {ReqCassette, cassette: ...}]`). Pass-through
      when nil; the orchestrators talk to the real model.

    * `:use_workflow` — when `true`, runs the pipeline through the
      `TravelPlanner.PlannerWorkflow` FSM instead of direct-calling
      the orchestrators. Defaults to `false`.

  ## Errors

  Returns `{:error, stage, reason}` where `stage` is one of:

    * `:gather` — gather orchestrator failed or produced no final text
    * `:assemble` — assemble orchestrator returned `{:error, reason}` or
      suspended unexpectedly
    * `:shape` — assemble completed but the result was not the expected
      `%{plan: [...]}` shape (typically a bug in `SubmitPlan`)
  """
  @spec run_task(TPTask.t(), keyword()) ::
          {:ok, plan()} | {:error, stage(), term()}
  def run_task(%TPTask{} = task, opts \\ []) do
    if Keyword.get(opts, :use_workflow, false) do
      run_task_workflow(task, opts)
    else
      run_task_direct(task, opts)
    end
  end

  defp run_task_direct(task, opts) do
    db = ReferenceInfo.parse(task.reference_information)

    with {:ok, summary} <- gather(task, db, opts),
         {:ok, raw_plan} <- assemble(task, summary, opts) do
      {:ok, TravelPlanner.PostProcess.fix(raw_plan, task, db)}
    end
  end

  defp run_task_workflow(task, opts) do
    alias TravelPlanner.PlannerWorkflow

    db = ReferenceInfo.parse(task.reference_information)
    req_options = Keyword.get(opts, :req_options)

    agent = PlannerWorkflow.new()

    context =
      %{task: task, reference_db: db}
      |> then(fn ctx ->
        if req_options, do: Map.put(ctx, :req_options, req_options), else: ctx
      end)

    case PlannerWorkflow.run_sync(agent, context) do
      {:ok, %{assemble: %{plan: plan}}} when is_list(plan) ->
        {:ok, plan}

      {:ok, result} ->
        {:error, :shape, {:bad_result_shape, result}}

      {:error, reason} ->
        stage = infer_failed_stage(reason)
        {:error, stage, reason}
    end
  end

  defp infer_failed_stage(reason) do
    case reason do
      {:no_final_message, _} -> :gather
      {:unexpected_suspension, _} -> :gather
      {:bad_result_shape, _} -> :shape
      _ -> :assemble
    end
  end

  # ─── stages ──────────────────────────────────────────────────────────────

  defp gather(task, db, opts) do
    agent =
      GatherOrchestrator.new()
      |> maybe_configure_req_options(GatherOrchestrator, opts)

    query = build_gather_query(task)
    ambient = %{reference_db: db, task: task}

    case GatherOrchestrator.query_sync(agent, query, ambient) do
      {:ok, _agent, result} when is_binary(result) and byte_size(result) > 0 ->
        {:ok, result}

      {:ok, _agent, result} ->
        {:error, :gather, {:no_final_message, result}}

      {:suspended, _agent, suspension} ->
        {:error, :gather, {:unexpected_suspension, suspension}}

      {:error, reason} ->
        {:error, :gather, reason}
    end
  end

  defp assemble(task, gather_summary, opts) do
    agent =
      AssembleOrchestrator.new()
      |> maybe_configure_req_options(AssembleOrchestrator, opts)

    query = build_assemble_query(task, gather_summary)
    ambient = %{task: task}

    case AssembleOrchestrator.query_sync(agent, query, ambient) do
      {:ok, _agent, %{plan: plan}} when is_list(plan) ->
        {:ok, plan}

      {:ok, _agent, result} ->
        {:error, :shape, {:bad_result_shape, result}}

      {:suspended, _agent, suspension} ->
        {:error, :assemble, {:unexpected_suspension, suspension}}

      {:error, reason} ->
        {:error, :assemble, reason}
    end
  end

  defp maybe_configure_req_options(agent, module, opts) do
    case Keyword.get(opts, :req_options) do
      nil -> agent
      req_options when is_list(req_options) -> module.configure(agent, req_options: req_options)
    end
  end

  # ─── query builders ──────────────────────────────────────────────────────

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
