defmodule Jido.Composer.Directive.SuspendForHuman do
  @moduledoc """
  Directive emitted by strategies when a flow suspends for human input.

  The runtime interprets this directive to:

  1. Deliver the ApprovalRequest through the configured notification channel
  2. Optionally start a timeout timer via a Schedule directive
  3. Optionally hibernate the agent for long-pause resource management
  """

  alias Jido.Composer.HITL.ApprovalRequest

  @enforce_keys [:approval_request]
  defstruct [:approval_request, :notification, hibernate: false]

  @type t :: %__MODULE__{
          approval_request: ApprovalRequest.t(),
          notification: term() | nil,
          hibernate: boolean() | map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs) do
    attrs_map = Map.new(attrs)

    with :ok <- validate_approval_request(attrs_map[:approval_request]) do
      {:ok,
       %__MODULE__{
         approval_request: attrs_map.approval_request,
         notification: Map.get(attrs_map, :notification),
         hibernate: Map.get(attrs_map, :hibernate, false)
       }}
    end
  end

  defp validate_approval_request(%ApprovalRequest{}), do: :ok
  defp validate_approval_request(nil), do: {:error, "approval_request is required"}

  defp validate_approval_request(_),
    do: {:error, "approval_request must be an ApprovalRequest struct"}
end
