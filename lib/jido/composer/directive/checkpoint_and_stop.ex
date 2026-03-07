defmodule Jido.Composer.Directive.CheckpointAndStop do
  @moduledoc """
  Directive for hibernating a child agent and signaling the parent.

  When executed by the runtime:
  1. Calls `Jido.Persist.hibernate/2` with the checkpoint data
  2. Emits `"composer.child.hibernated"` to the parent agent
  3. Stops the child process
  """

  @enforce_keys [:suspension]
  defstruct [:suspension, :storage_config, :checkpoint_data]

  @type t :: %__MODULE__{
          suspension: map(),
          storage_config: map() | nil,
          checkpoint_data: map() | nil
        }
end
