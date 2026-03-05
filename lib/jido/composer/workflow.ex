defmodule Jido.Composer.Workflow do
  @moduledoc """
  DSL entry point for defining workflow agents.

  See `Jido.Composer.Workflow.DSL` for full documentation.
  """

  defmacro __using__(opts) do
    quote do
      use Jido.Composer.Workflow.DSL, unquote(opts)
    end
  end
end
