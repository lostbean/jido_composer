defmodule Jido.Composer.Orchestrator do
  @moduledoc """
  DSL entry point for defining orchestrator agents.

  See `Jido.Composer.Orchestrator.DSL` for full documentation.
  """

  defmacro __using__(opts) do
    quote do
      use Jido.Composer.Orchestrator.DSL, unquote(opts)
    end
  end
end
