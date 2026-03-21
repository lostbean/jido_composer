defmodule Jido.Composer.Node.DynamicAgentNode do
  @moduledoc """
  Node that assembles and executes a sub-agent from selected skills at runtime.

  DynamicAgentNode wraps `Skill.assemble/2` and `query_sync/3` behind the Node
  interface. When used as a tool in an Orchestrator, the parent LLM selects
  skills by name and provides a task description. The node looks up the skills,
  assembles a configured Orchestrator, runs it, and returns the result.

  ## Fields

    * `name` — node identifier (becomes tool name in orchestrator)
    * `description` — what this delegation node does
    * `skill_registry` — list of available `Skill` structs
    * `assembly_opts` — options passed to `Skill.assemble/2`
  """

  @behaviour Jido.Composer.Node

  @enforce_keys [:name, :description, :skill_registry]
  defstruct [:name, :description, :skill_registry, assembly_opts: []]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          skill_registry: [Jido.Composer.Skill.t()],
          assembly_opts: keyword()
        }

  @impl true
  @spec run(t(), map(), keyword()) :: Jido.Composer.Node.result()
  def run(%__MODULE__{} = node, context, _opts) do
    task = Map.get(context, :task) || Map.get(context, "task", "")
    skill_names = Map.get(context, :skills) || Map.get(context, "skills", [])

    with {:ok, skills} <- lookup_skills(node.skill_registry, skill_names),
         {:ok, agent} <- Jido.Composer.Skill.assemble(skills, node.assembly_opts) do
      case Jido.Composer.Skill.BaseOrchestrator.query_sync(agent, task) do
        {:ok, _agent, result} -> {:ok, result}
        {:suspended, _agent, suspension} -> {:error, {:suspended, suspension}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  @spec name(t()) :: String.t()
  def name(%__MODULE__{name: name}), do: name

  @impl true
  @spec description(t()) :: String.t()
  def description(%__MODULE__{description: desc}), do: desc

  @impl true
  @spec schema(t()) :: keyword()
  def schema(%__MODULE__{}) do
    [
      task: [type: :string, required: true, doc: "The task for the sub-agent to accomplish"],
      skills: [type: {:list, :string}, required: true, doc: "List of skill names to equip"]
    ]
  end

  @impl true
  @spec to_tool_spec(t()) :: map()
  def to_tool_spec(%__MODULE__{} = node) do
    %{
      name: node.name,
      description: node.description,
      parameter_schema: Jido.Action.Tool.build_parameters_schema(schema(node))
    }
  end

  @impl true
  @spec to_directive(t(), map(), keyword()) :: Jido.Composer.Node.directive_result()
  def to_directive(%__MODULE__{} = node, flat_context, opts) do
    result_action = Keyword.get(opts, :result_action, :orchestrator_tool_result)
    meta = Keyword.get(opts, :meta, %{})
    tool_args = Keyword.get(opts, :tool_args, %{})

    # Merge tool_args into context for skill/task extraction
    context = Map.merge(flat_context, tool_args)

    instruction = %Jido.Instruction{
      action: Jido.Composer.Node.DynamicAgentNode.ExecuteAction,
      params: %{__node__: node, __context__: context}
    }

    directive = %Jido.Agent.Directive.RunInstruction{
      instruction: instruction,
      result_action: result_action,
      meta: meta
    }

    {:ok, [directive]}
  end

  defp lookup_skills(registry, skill_names) do
    registry_map = Map.new(registry, &{&1.name, &1})

    result =
      Enum.reduce_while(skill_names, [], fn name, acc ->
        case Map.get(registry_map, name) do
          nil -> {:halt, {:error, "Skill not found: #{name}"}}
          skill -> {:cont, [skill | acc]}
        end
      end)

    case result do
      {:error, _} = err -> err
      skills -> {:ok, Enum.reverse(skills)}
    end
  end
end
