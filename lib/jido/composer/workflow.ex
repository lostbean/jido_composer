defmodule Jido.Composer.Workflow do
  @moduledoc """
  Deterministic FSM workflow DSL.

  `use Jido.Composer.Workflow` generates a `Jido.Agent` module with an FSM
  where each state binds to an action, agent, fan-out, or human gate.
  Transitions are fully determined by node outcomes.

  ## Example

      defmodule ETLPipeline do
        use Jido.Composer.Workflow,
          name: "etl_pipeline",
          nodes: %{
            extract:   ExtractAction,
            transform: TransformAction,
            load:      LoadAction
          },
          transitions: %{
            {:extract, :ok}   => :transform,
            {:transform, :ok} => :load,
            {:load, :ok}      => :done,
            {:_, :error}      => :failed
          },
          initial: :extract
      end

      agent = ETLPipeline.new()
      {:ok, result} = ETLPipeline.run_sync(agent, %{source: "customer_db"})
      result[:load][:loaded] #=> 2

  ## Terminal and Success States

  By convention, `:done` and `:failed` are the default terminal states, with
  `:done` as the sole success state. To customize, provide **both**
  `terminal_states` and `success_states`:

      terminal_states: [:completed, :errored, :cancelled],
      success_states: [:completed]

  Any terminal state not in `success_states` is a failure. When no node error
  was captured, the terminal state atom itself becomes the error reason
  (e.g., `{:error, :cancelled}`).

  ## Generated Functions

  - `new/0` — Create a new agent instance
  - `run/2` — Start the workflow, returns `{agent, directives}`
  - `run_sync/2` — Run to completion, returns `{:ok, result}` or `{:error, reason}`.
    On failure, `reason` is the original error from the failing node — typically a
    `Jido.Action.Error` struct, a child agent's error, or a transition error.
    When no node error was captured, the terminal state atom is the reason.
    Callers can pattern-match on the error type for specific handling.

  See the [Workflows Guide](workflows.md) for all DSL options, node types,
  transitions, fan-out, and compile-time validation.

  See `Jido.Composer.Workflow.DSL` for implementation details.
  """

  defmacro __using__(opts) do
    quote do
      use Jido.Composer.Workflow.DSL, unquote(opts)
    end
  end
end
