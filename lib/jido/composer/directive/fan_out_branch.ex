defmodule Jido.Composer.Directive.FanOutBranch do
  @moduledoc """
  Directive emitted per-branch when the Workflow strategy encounters a FanOutNode.

  Each FanOutBranch carries either an `instruction` (for ActionNode branches)
  or a `spawn_agent` (for AgentNode branches), but not both. The runtime
  executes these concurrently and feeds results back via the
  `fan_out_branch_result` command.
  """

  @enforce_keys [:fan_out_id, :branch_name]
  defstruct [:fan_out_id, :branch_name, :instruction, :spawn_agent, :result_action, :timeout]

  @type t :: %__MODULE__{
          fan_out_id: String.t(),
          branch_name: atom(),
          instruction: Jido.Instruction.t() | nil,
          spawn_agent: map() | nil,
          result_action: atom() | nil,
          timeout: pos_integer() | nil
        }
end
