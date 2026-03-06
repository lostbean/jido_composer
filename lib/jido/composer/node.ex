defmodule Jido.Composer.Node do
  @moduledoc """
  Uniform context-in/context-out interface for workflow participants.

  Every participant in a composition — actions, agents, nested workflows —
  implements this behaviour. Nodes form an endomorphism monoid over context
  maps, composed via Kleisli arrows.

  ## Return Types

  - `{:ok, context}` — success with implicit outcome `:ok`
  - `{:ok, context, outcome}` — success with explicit outcome for FSM transitions
  - `{:error, reason}` — failure with implicit outcome `:error`
  """

  @type context :: map()
  @type outcome :: atom()
  @type result :: {:ok, context()} | {:ok, context(), outcome()} | {:error, term()}

  @callback run(node :: struct(), context :: context(), opts :: keyword()) :: result()
  @callback name(node :: struct()) :: String.t()
  @callback description(node :: struct()) :: String.t()
  @callback schema(node :: struct()) :: keyword() | nil
  @callback input_type(node :: struct()) :: :map | :text | :object | :any
  @callback output_type(node :: struct()) :: :map | :text | :object | :any

  @optional_callbacks [schema: 1, input_type: 1, output_type: 1]
end
