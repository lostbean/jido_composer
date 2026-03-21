defmodule Jido.Composer.NodeTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Node

  defmodule ValidNode do
    @behaviour Node

    defstruct []

    @impl Node
    def run(_node, context, _opts), do: {:ok, Map.put(context, :ran, true)}

    @impl Node
    def name(_node), do: "valid_node"

    @impl Node
    def description(_node), do: "A test node"

    @impl Node
    def schema(_node), do: [input: [type: :string, required: true]]
  end

  defmodule OutcomeNode do
    @behaviour Node

    defstruct []

    @impl Node
    def run(_node, context, _opts), do: {:ok, context, :custom_outcome}

    @impl Node
    def name(_node), do: "outcome_node"

    @impl Node
    def description(_node), do: "Returns explicit outcome"

    @impl Node
    def schema(_node), do: nil
  end

  defmodule ErrorNode do
    @behaviour Node

    defstruct []

    @impl Node
    def run(_node, _context, _opts), do: {:error, "something went wrong"}

    @impl Node
    def name(_node), do: "error_node"

    @impl Node
    def description(_node), do: "Always errors"

    @impl Node
    def schema(_node), do: nil
  end

  describe "behaviour contract" do
    test "module implementing Node can return {:ok, context}" do
      assert {:ok, %{ran: true}} = ValidNode.run(%ValidNode{}, %{}, [])
    end

    test "module implementing Node can return {:ok, context, outcome}" do
      assert {:ok, %{}, :custom_outcome} = OutcomeNode.run(%OutcomeNode{}, %{}, [])
    end

    test "module implementing Node can return {:error, reason}" do
      assert {:error, "something went wrong"} = ErrorNode.run(%ErrorNode{}, %{}, [])
    end

    test "name/1 returns a string" do
      assert is_binary(ValidNode.name(%ValidNode{}))
    end

    test "description/1 returns a string" do
      assert is_binary(ValidNode.description(%ValidNode{}))
    end

    test "schema/1 returns keyword list or nil" do
      assert is_list(ValidNode.schema(%ValidNode{}))
      assert is_nil(OutcomeNode.schema(%OutcomeNode{}))
    end
  end

  describe "compiler enforcement" do
    test "behaviour defines all required callbacks" do
      callbacks = Node.behaviour_info(:callbacks)
      assert {:run, 3} in callbacks
      assert {:name, 1} in callbacks
      assert {:description, 1} in callbacks
    end

    test "schema is optional" do
      optional = Node.behaviour_info(:optional_callbacks)
      assert {:schema, 1} in optional
    end
  end

  describe "node?/1" do
    test "returns true for a module that declares the Node behaviour" do
      assert Node.node?(ValidNode)
    end

    test "returns false for a module that does not declare the Node behaviour" do
      refute Node.node?(URI)
    end

    test "returns false for a non-existent module" do
      refute Node.node?(NonExistentModule12345)
    end
  end

  describe "dispatch_name/1" do
    test "extracts name from a ValidNode struct" do
      assert Node.dispatch_name(%ValidNode{}) == "valid_node"
    end

    test "raises ArgumentError for a struct that does not implement Node" do
      assert_raise ArgumentError, ~r/does not implement the Node behaviour/, fn ->
        Node.dispatch_name(%URI{path: "/test"})
      end
    end
  end
end
