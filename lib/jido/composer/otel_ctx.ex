defmodule Jido.Composer.OtelCtx do
  @moduledoc """
  Centralized OpenTelemetry context management for jido_composer.

  Wraps OTel process-dictionary context save/attach/restore into safe
  higher-order functions with guaranteed cleanup via try/after.

  All calls use `apply/3` to avoid compile-time warnings when
  OpenTelemetry is an optional (test-only) dependency.
  """

  @otel_ctx OpenTelemetry.Ctx

  @doc """
  Executes `fun` with the given OTel context attached, then restores the
  previous context. If `ctx` is nil or OpenTelemetry is not loaded, just
  calls `fun` directly.
  """
  @spec with_parent_context(term() | nil, (-> result)) :: result when result: var
  def with_parent_context(nil, fun), do: fun.()

  def with_parent_context(ctx, fun) do
    if Code.ensure_loaded?(@otel_ctx) do
      saved = apply(@otel_ctx, :get_current, [])

      apply(@otel_ctx, :attach, [ctx])

      try do
        fun.()
      after
        if saved, do: apply(@otel_ctx, :attach, [saved])
      end
    else
      fun.()
    end
  end

  @doc "Returns the current OTel context, or nil if OpenTelemetry is not loaded."
  @spec get_current() :: term() | nil
  def get_current do
    if Code.ensure_loaded?(@otel_ctx), do: apply(@otel_ctx, :get_current, [])
  end

  @doc "Attaches the given OTel context. No-op if nil or OpenTelemetry is not loaded."
  @spec attach(term() | nil) :: :ok
  def attach(nil), do: :ok

  def attach(ctx) do
    if Code.ensure_loaded?(@otel_ctx), do: apply(@otel_ctx, :attach, [ctx])
    :ok
  end
end
