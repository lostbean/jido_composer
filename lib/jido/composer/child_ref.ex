defmodule Jido.Composer.ChildRef do
  @moduledoc """
  Serializable reference to a child agent process.

  Replaces raw PIDs in strategy state for checkpoint/thaw safety.
  Contains all information needed to re-spawn a child from its
  checkpoint on resume.

  This is a top-level Composer concept (not HITL-specific) since any
  suspension reason requires serializable child tracking.
  """

  @derive Jason.Encoder

  defstruct [:agent_module, :agent_id, :tag, :checkpoint_key, :suspension_id, status: :running]

  @type status :: :running | :paused | :hibernated | :completed | :failed

  @type t :: %__MODULE__{
          agent_module: module(),
          agent_id: String.t(),
          tag: term(),
          checkpoint_key: term(),
          suspension_id: String.t() | nil,
          status: status()
        }

  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    %__MODULE__{
      agent_module: Keyword.fetch!(attrs, :agent_module),
      agent_id: Keyword.fetch!(attrs, :agent_id),
      tag: Keyword.fetch!(attrs, :tag),
      checkpoint_key: Keyword.get(attrs, :checkpoint_key),
      suspension_id: Keyword.get(attrs, :suspension_id),
      status: Keyword.get(attrs, :status, :running)
    }
  end
end
