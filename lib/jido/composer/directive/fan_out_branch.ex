defmodule Jido.Composer.Directive.FanOutBranch do
  @moduledoc """
  Directive emitted per-branch when the Workflow strategy encounters a FanOutNode
  or MapNode.

  Each FanOutBranch carries a `child_node` (any Node struct) and `params`
  (execution context map). The runtime dispatches execution uniformly via
  `child_node.__struct__.run(child_node, params, [])`.
  """

  @enforce_keys [:fan_out_id, :branch_name, :child_node]
  defstruct [:fan_out_id, :branch_name, :child_node, :params, :result_action, :timeout]

  @type t :: %__MODULE__{
          fan_out_id: String.t(),
          branch_name: atom(),
          child_node: struct(),
          params: map() | nil,
          result_action: atom() | nil,
          timeout: pos_integer() | nil
        }
end
