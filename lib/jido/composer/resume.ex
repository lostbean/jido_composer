defmodule Jido.Composer.Resume do
  @moduledoc """
  External-facing API for resuming suspended agents.

  Handles both live agents (deliver signal directly) and checkpointed
  agents (thaw from storage, then deliver). Provides idempotency via
  suspension ID matching.

  ## Options

  - `:deliver_fn` — `(agent, signal) -> {agent, directives}`. Required.
    Delivers the resume signal to a live agent.
  - `:thaw_fn` — `(agent_id) -> {:ok, agent} | {:error, reason}`. Optional.
    Restores an agent from checkpoint storage.
  - `:agent_id` — `String.t()`. Required when `agent` is nil and `:thaw_fn`
    is provided.
  - `:storage` — Map with `compare_and_set_status/3` callback. Optional.
    When provided, performs CAS on checkpoint status for idempotent resume.
  """

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Checkpoint
  alias Jido.Composer.Suspension

  @spec resume(Jido.Agent.t() | nil, String.t(), map(), keyword()) ::
          {:ok, Jido.Agent.t(), list()} | {:error, term()}
  def resume(agent, suspension_id, resume_data, opts \\ []) do
    deliver_fn = Keyword.fetch!(opts, :deliver_fn)
    thaw_fn = Keyword.get(opts, :thaw_fn)
    agent_id = Keyword.get(opts, :agent_id)
    storage = Keyword.get(opts, :storage)

    case resolve_agent(agent, thaw_fn, agent_id) do
      {:ok, live_agent} ->
        with :ok <- maybe_transition_status(storage, live_agent, :hibernated, :resuming) do
          case deliver_resume(live_agent, suspension_id, resume_data, deliver_fn) do
            {:ok, resumed_agent, directives} ->
              maybe_transition_status(storage, resumed_agent, :resuming, :resumed)
              {:ok, resumed_agent, directives}

            error ->
              error
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_agent(%Jido.Agent{} = agent, _thaw_fn, _agent_id), do: {:ok, agent}

  defp resolve_agent(nil, thaw_fn, agent_id)
       when is_function(thaw_fn, 1) and not is_nil(agent_id) do
    thaw_fn.(agent_id)
  end

  defp resolve_agent(nil, _thaw_fn, _agent_id), do: {:error, :agent_not_available}

  defp deliver_resume(agent, suspension_id, resume_data, deliver_fn) do
    strat = StratState.get(agent)

    # Check if there's a matching suspension
    cond do
      match?(%Suspension{id: ^suspension_id}, Map.get(strat, :pending_suspension)) ->
        signal = {:suspend_resume, Map.put(resume_data, :suspension_id, suspension_id)}
        {resumed_agent, directives} = deliver_fn.(agent, signal)
        child_directives = child_respawn_directives(resumed_agent)
        {:ok, resumed_agent, directives ++ child_directives}

      has_suspended_call?(strat, suspension_id) ->
        signal = {:suspend_resume, Map.put(resume_data, :suspension_id, suspension_id)}
        {resumed_agent, directives} = deliver_fn.(agent, signal)
        child_directives = child_respawn_directives(resumed_agent)
        {:ok, resumed_agent, directives ++ child_directives}

      has_suspended_fan_out_branch?(strat, suspension_id) ->
        signal = {:suspend_resume, Map.put(resume_data, :suspension_id, suspension_id)}
        {resumed_agent, directives} = deliver_fn.(agent, signal)
        child_directives = child_respawn_directives(resumed_agent)
        {:ok, resumed_agent, directives ++ child_directives}

      true ->
        {:error, :no_matching_suspension}
    end
  end

  defp maybe_transition_status(nil, _agent, _from, _to), do: :ok

  defp maybe_transition_status(storage, agent, from, to) do
    with :ok <- Checkpoint.transition_status(from, to) do
      agent_key = agent.id
      storage.compare_and_set_status.(agent_key, from, to)
    end
  end

  defp has_suspended_call?(strat, suspension_id) do
    case Map.get(strat, :suspended_calls, %{}) do
      calls when is_map(calls) -> Map.has_key?(calls, suspension_id)
      _ -> false
    end
  end

  defp child_respawn_directives(agent) do
    strat = StratState.get(agent)
    Checkpoint.pending_child_respawns(strat)
  end

  defp has_suspended_fan_out_branch?(strat, suspension_id) do
    case Map.get(strat, :pending_fan_out) do
      %{suspended_branches: branches} when is_map(branches) and branches != %{} ->
        Enum.any?(branches, fn {_name, %{suspension: %Suspension{id: id}}} ->
          id == suspension_id
        end)

      _ ->
        false
    end
  end
end
