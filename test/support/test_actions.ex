defmodule Jido.Composer.TestActions do
  @moduledoc false

  defmodule AddAction do
    @moduledoc false
    use Jido.Action,
      name: "add",
      description: "Adds an amount to a value",
      schema: [
        value: [type: :float, required: true, doc: "The current value"],
        amount: [type: :float, required: true, doc: "The amount to add"]
      ]

    def run(%{value: value, amount: amount}, _context) do
      {:ok, %{result: value + amount}}
    end
  end

  defmodule MultiplyAction do
    @moduledoc false
    use Jido.Action,
      name: "multiply",
      description: "Multiplies a value by an amount",
      schema: [
        value: [type: :float, required: true, doc: "The current value"],
        amount: [type: :float, required: true, doc: "The multiplier"]
      ]

    def run(%{value: value, amount: amount}, _context) do
      {:ok, %{result: value * amount}}
    end
  end

  defmodule FailAction do
    @moduledoc false
    use Jido.Action,
      name: "fail",
      description: "Always fails with an error",
      schema: [
        reason: [type: :string, required: false, doc: "The failure reason"]
      ]

    def run(params, _context) do
      {:error, Map.get(params, :reason, "intentional failure")}
    end
  end

  defmodule RaiseAction do
    @moduledoc false
    use Jido.Action,
      name: "raise",
      description: "Always raises an exception",
      schema: []

    def run(_params, _context) do
      raise RuntimeError, "action raised!"
    end
  end

  defmodule SlowAction do
    @moduledoc false
    use Jido.Action,
      name: "slow",
      description: "Simulates a slow operation",
      schema: [
        delay_ms: [type: :pos_integer, required: true, doc: "Delay in milliseconds"],
        value: [type: :any, required: false, doc: "Value to return"]
      ]

    def run(%{delay_ms: delay} = params, _context) do
      Process.sleep(delay)
      {:ok, %{result: Map.get(params, :value, :done)}}
    end
  end

  defmodule NoopAction do
    @moduledoc false
    use Jido.Action,
      name: "noop",
      description: "Does nothing, returns empty result",
      schema: []

    def run(_params, _context) do
      {:ok, %{}}
    end
  end

  defmodule EchoAction do
    @moduledoc false
    use Jido.Action,
      name: "echo",
      description: "Echoes input params as the result",
      schema: [
        message: [type: :string, required: true, doc: "Message to echo"]
      ]

    def run(%{message: message}, _context) do
      {:ok, %{echoed: message}}
    end
  end

  defmodule ExtractAction do
    @moduledoc false
    use Jido.Action,
      name: "extract",
      description: "Simulates data extraction, returns raw records",
      schema: [
        source: [type: :string, required: true, doc: "Data source identifier"]
      ]

    def run(%{source: source}, _context) do
      {:ok, %{records: [%{id: 1, source: source}, %{id: 2, source: source}], count: 2}}
    end
  end

  defmodule TransformAction do
    @moduledoc false
    use Jido.Action,
      name: "transform",
      description: "Transforms extracted records by uppercasing source",
      schema: [
        extract: [type: :map, required: false, doc: "Results from extract step"]
      ]

    def run(params, _context) do
      records = get_in(params, [:extract, :records]) || []

      transformed =
        Enum.map(records, fn rec ->
          Map.update(rec, :source, "", &String.upcase/1)
        end)

      {:ok, %{records: transformed, count: length(transformed)}}
    end
  end

  defmodule LoadAction do
    @moduledoc false
    use Jido.Action,
      name: "load",
      description: "Simulates loading records into storage",
      schema: [
        transform: [type: :map, required: false, doc: "Results from transform step"]
      ]

    def run(params, _context) do
      records = get_in(params, [:transform, :records]) || []
      {:ok, %{loaded: length(records), status: :complete}}
    end
  end

  defmodule ValidateAction do
    @moduledoc false
    use Jido.Action,
      name: "validate",
      description: "Validates data, succeeds or fails based on valid flag",
      schema: [
        valid: [type: :boolean, required: true, doc: "Whether validation passes"]
      ]

    def run(%{valid: true}, _context) do
      {:ok, %{validated: true}}
    end

    def run(%{valid: false}, _context) do
      {:error, "validation failed"}
    end
  end

  defmodule AccumulatorAction do
    @moduledoc false
    use Jido.Action,
      name: "accumulator",
      description: "Appends a tag to an accumulator list",
      schema: [
        tag: [type: :string, required: true, doc: "Tag to append"]
      ]

    def run(%{tag: tag}, _context) do
      {:ok, %{tag: tag}}
    end
  end

  defmodule ValidateOutcomeAction do
    @moduledoc false
    use Jido.Action,
      name: "validate_outcome",
      description: "Returns custom outcome based on data validity",
      schema: [
        data: [type: :string, required: true, doc: "Data to validate"]
      ]

    def run(%{data: "valid"}, _context) do
      {:ok, %{validated: true, quality: :good}}
    end

    def run(%{data: "invalid"}, _context) do
      {:ok, %{validated: false, quality: :bad}, :invalid}
    end

    def run(%{data: "retry"}, _context) do
      {:ok, %{validated: false, quality: :unstable}, :retry}
    end

    def run(%{data: _}, _context) do
      {:error, "unrecognized data"}
    end
  end

  defmodule SuspendAction do
    @moduledoc false
    use Jido.Action,
      name: "suspend",
      description: "Returns a suspend outcome to pause the workflow",
      schema: [
        checkpoint: [type: :string, required: false, doc: "Checkpoint label"]
      ]

    def run(params, _context) do
      {:ok, %{checkpoint: Map.get(params, :checkpoint, "paused")}, :suspend}
    end
  end

  defmodule RateLimitAction do
    @moduledoc false
    use Jido.Action,
      name: "rate_limit_action",
      description: "Simulates a rate-limited operation that suspends",
      schema: [
        tokens: [type: :integer, required: false, doc: "Tokens remaining"]
      ]

    def run(params, _context) do
      tokens = Map.get(params, :tokens, 0)

      if tokens > 0 do
        {:ok, %{processed: true, tokens_remaining: tokens - 1}}
      else
        {:ok, suspension} =
          Jido.Composer.Suspension.new(
            reason: :rate_limit,
            metadata: %{retry_after_ms: 5000}
          )

        {:ok, %{processed: false, __suspension__: suspension}, :suspend}
      end
    end
  end

  defmodule TimedSuspendAction do
    @moduledoc false
    use Jido.Action,
      name: "timed_suspend_action",
      description: "Suspends with a finite timeout for CheckpointAndStop testing",
      schema: [
        timeout_ms: [type: :integer, required: false, doc: "Suspension timeout in ms"]
      ]

    def run(params, _context) do
      timeout_ms = Map.get(params, :timeout_ms, 30_000)

      {:ok, suspension} =
        Jido.Composer.Suspension.new(
          reason: :async_completion,
          timeout: timeout_ms,
          metadata: %{operation: "timed_suspend"}
        )

      {:ok, %{suspended: true, __suspension__: suspension}, :suspend}
    end
  end

  defmodule FinalReportAction do
    @moduledoc false
    use Jido.Action,
      name: "final_report",
      description: "Produces a structured final report. Call when you have the answer.",
      schema: [
        summary: [type: :string, required: true, doc: "Summary of findings"],
        confidence: [type: :float, required: true, doc: "Confidence score 0.0-1.0"]
      ]

    def run(%{summary: summary, confidence: confidence}, _context) do
      {:ok, %{summary: summary, confidence: confidence}}
    end
  end

  defmodule AmbientEchoAction do
    @moduledoc false
    use Jido.Action,
      name: "ambient_echo",
      description: "Echoes a message along with the ambient :actor value",
      schema: [
        message: [type: :string, required: true, doc: "Message to echo"]
      ]

    def run(params, _context) do
      ambient = Map.get(params, Jido.Composer.Context.ambient_key(), %{})
      actor = Map.get(ambient, :actor)

      case actor do
        nil -> {:error, "Missing :actor in ambient context"}
        _ -> {:ok, %{echoed: params.message, actor: actor}}
      end
    end
  end

  defmodule AmbientFinalReportAction do
    @moduledoc false
    use Jido.Action,
      name: "ambient_final_report",
      description: "Termination tool that reads ambient context and includes it in the result.",
      schema: [
        summary: [type: :string, required: true, doc: "Summary of findings"],
        confidence: [type: :float, required: true, doc: "Confidence score 0.0-1.0"]
      ]

    def run(params, _context) do
      ambient = Map.get(params, Jido.Composer.Context.ambient_key(), %{})
      actor = Map.get(ambient, :actor)

      case actor do
        nil -> {:error, "Missing :actor in ambient context"}
        _ -> {:ok, %{summary: params.summary, confidence: params.confidence, actor: actor}}
      end
    end
  end

  defmodule FailingFinalReportAction do
    @moduledoc false
    use Jido.Action,
      name: "failing_final_report",
      description: "A termination tool that always fails validation.",
      schema: [
        summary: [type: :string, required: true, doc: "Summary"],
        confidence: [type: :float, required: true, doc: "Confidence"]
      ]

    def run(_params, _context) do
      {:error, "validation failed: confidence out of range"}
    end
  end

  defmodule AskUserAction do
    @moduledoc false
    use Jido.Action,
      name: "ask_user",
      description:
        "Ask the user a clarifying question. Call this when you need input before proceeding.",
      schema: [
        question_text: [type: :string, required: true, doc: "The question to ask the user"],
        options: [type: {:list, :string}, required: false, doc: "Optional list of choices"],
        input_type: [
          type: :string,
          required: false,
          doc: "Expected input type: text, choice, or confirm"
        ]
      ]

    def run(params, _context) do
      {:ok,
       %{
         question: params.question_text,
         options: Map.get(params, :options, []),
         input_type: Map.get(params, :input_type, "text")
       }, :suspend}
    end
  end

  defmodule ReadFileAction do
    @moduledoc false
    use Jido.Action,
      name: "read_file",
      description: "Reads a file and returns its content as multimodal ContentParts",
      schema: [
        file_id: [type: :integer, required: true, doc: "The file ID to read"]
      ]

    alias ReqLLM.Message.ContentPart
    alias ReqLLM.ToolResult

    def run(%{file_id: file_id}, _context) do
      # Simulate returning multimodal content: a text description + an image.
      # Uses ReqLLM.ToolResult so the orchestrator can pass content parts
      # directly to the LLM conversation (images, files, etc.).
      image_data = <<137, 80, 78, 71, 13, 10, 26, 10>>

      {:ok,
       %ToolResult{
         content: [
           ContentPart.text("Here is the file you requested (ID: #{file_id}):"),
           ContentPart.image(image_data, "image/png")
         ]
       }}
    end
  end

  defmodule SaveResultAction do
    @moduledoc false
    use Jido.Action,
      name: "save_result",
      description: "Save the final analysis result. Call when you have completed your analysis.",
      schema: [
        answer: [type: :string, required: true, doc: "The final answer"],
        analysis: [type: :string, required: true, doc: "Summary of the analysis performed"]
      ]

    def run(%{answer: answer, analysis: analysis}, _context) do
      {:ok, %{answer: answer, analysis: analysis}}
    end
  end
end
