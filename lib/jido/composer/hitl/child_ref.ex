defmodule Jido.Composer.HITL.ChildRef do
  @moduledoc """
  Serializable reference to a child agent process.

  Replaces raw PIDs in strategy state for checkpoint/thaw safety.
  Contains all information needed to re-spawn a child from its
  checkpoint on resume.
  """

  @derive Jason.Encoder

  defstruct [:agent_module, :agent_id, :tag, :checkpoint_key, status: :running]

  @type status :: :running | :paused | :completed | :failed

  @type t :: %__MODULE__{
          agent_module: module(),
          agent_id: String.t(),
          tag: term(),
          checkpoint_key: term(),
          status: status()
        }

  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    %__MODULE__{
      agent_module: Keyword.fetch!(attrs, :agent_module),
      agent_id: Keyword.fetch!(attrs, :agent_id),
      tag: Keyword.fetch!(attrs, :tag),
      checkpoint_key: Keyword.get(attrs, :checkpoint_key),
      status: Keyword.get(attrs, :status, :running)
    }
  end
end
