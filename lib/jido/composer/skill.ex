defmodule Jido.Composer.Skill do
  @moduledoc """
  Reusable capability bundle for runtime agent assembly.

  A Skill is pure data: a name, description, prompt fragment, and list of tool
  modules. Skills are composed at runtime via `assemble/2` to create dynamically
  configured Orchestrator agents.

  ## Example

      math_skill = %Skill{
        name: "math",
        description: "Arithmetic operations",
        prompt_fragment: "Use add and multiply tools for calculations.",
        tools: [AddAction, MultiplyAction]
      }

      {:ok, agent} = Skill.assemble([math_skill],
        base_prompt: "You are a calculator.",
        model: "anthropic:claude-sonnet-4-20250514"
      )
  """

  @enforce_keys [:name, :description, :prompt_fragment, :tools]
  defstruct [:name, :description, :prompt_fragment, :tools]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          prompt_fragment: String.t(),
          tools: [module()]
        }

  @doc """
  Assembles a list of skills into a configured Orchestrator agent.

  Composes prompt fragments, deduplicates tools, and returns an agent ready
  for `query_sync/3`.

  ## Options

    * `:base_prompt` — role instructions prepended to skill fragments
    * `:model` — LLM model identifier (e.g. `"anthropic:claude-sonnet-4-20250514"`)
    * `:max_iterations` — ReAct loop limit (passed to configure)
    * `:temperature` — LLM temperature (passed to configure)
    * `:max_tokens` — max tokens (passed to configure)
    * `:req_options` — HTTP options (passed to configure)
  """
  @allowed_opts ~w(base_prompt model temperature max_tokens max_iterations req_options)a

  @spec assemble([t()], keyword()) :: {:ok, Jido.Agent.t()} | {:error, term()}
  def assemble(skills, opts \\ []) when is_list(skills) and is_list(opts) do
    with :ok <- validate_opts(opts) do
      {base_prompt, configure_opts} = Keyword.pop(opts, :base_prompt)

      system_prompt = compose_prompt(skills, base_prompt)
      tools = collect_tools(skills)

      agent = Jido.Composer.Skill.BaseOrchestrator.new()

      configure_overrides =
        [{:system_prompt, system_prompt}, {:nodes, tools}] ++
          Keyword.take(configure_opts, [
            :model,
            :temperature,
            :max_tokens,
            :max_iterations,
            :req_options
          ])

      agent = Jido.Composer.Skill.BaseOrchestrator.configure(agent, configure_overrides)

      {:ok, agent}
    end
  end

  defp compose_prompt([], nil), do: ""

  defp compose_prompt([], base_prompt), do: base_prompt

  defp compose_prompt(skills, nil) do
    fragments = Enum.map_join(skills, "\n\n", & &1.prompt_fragment)
    "## Capabilities\n\n#{fragments}"
  end

  defp compose_prompt(skills, base_prompt) do
    fragments = Enum.map_join(skills, "\n\n", & &1.prompt_fragment)
    "#{base_prompt}\n\n## Capabilities\n\n#{fragments}"
  end

  defp validate_opts(opts) do
    case Keyword.keys(opts) -- @allowed_opts do
      [] ->
        :ok

      unknown ->
        {:error,
         %ArgumentError{
           message:
             "unknown assemble option(s): #{inspect(unknown)}. " <>
               "Allowed options: #{inspect(@allowed_opts)}"
         }}
    end
  end

  defp collect_tools(skills) do
    skills
    |> Enum.flat_map(& &1.tools)
    |> Enum.uniq()
  end
end
