defmodule Jido.Composer.NodeIOTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.NodeIO

  describe "map/1" do
    test "wraps map value" do
      io = NodeIO.map(%{key: "value"})
      assert %NodeIO{type: :map, value: %{key: "value"}} = io
    end
  end

  describe "text/1" do
    test "wraps string" do
      io = NodeIO.text("hello")
      assert %NodeIO{type: :text, value: "hello"} = io
    end
  end

  describe "object/2" do
    test "wraps with schema" do
      schema = %{"type" => "object", "properties" => %{"score" => %{"type" => "number"}}}
      io = NodeIO.object(%{score: 0.9}, schema)
      assert %NodeIO{type: :object, value: %{score: 0.9}, schema: ^schema} = io
    end

    test "wraps without schema" do
      io = NodeIO.object(%{score: 0.9})
      assert %NodeIO{type: :object, value: %{score: 0.9}, schema: nil} = io
    end
  end

  describe "to_map/1" do
    test "passes through map type" do
      assert %{a: 1} = NodeIO.to_map(NodeIO.map(%{a: 1}))
    end

    test "wraps text as %{text: value}" do
      assert %{text: "hello"} = NodeIO.to_map(NodeIO.text("hello"))
    end

    test "wraps object as %{object: value}" do
      assert %{object: %{score: 0.9}} = NodeIO.to_map(NodeIO.object(%{score: 0.9}))
    end
  end

  describe "unwrap/1" do
    test "returns raw value" do
      assert "hello" = NodeIO.unwrap(NodeIO.text("hello"))
      assert %{a: 1} = NodeIO.unwrap(NodeIO.map(%{a: 1}))
      assert %{score: 0.9} = NodeIO.unwrap(NodeIO.object(%{score: 0.9}))
    end
  end

  describe "mergeable?/1" do
    test "true only for :map" do
      assert NodeIO.mergeable?(NodeIO.map(%{a: 1}))
      refute NodeIO.mergeable?(NodeIO.text("hello"))
      refute NodeIO.mergeable?(NodeIO.object(%{a: 1}))
    end
  end

  describe "Jason encoding" do
    test "Jason encoding works" do
      io = NodeIO.text("hello")
      assert {:ok, json} = Jason.encode(io)
      assert is_binary(json)

      decoded = Jason.decode!(json)
      assert decoded["type"] == "text"
      assert decoded["value"] == "hello"
    end

    test "Jason encoding works for map type" do
      io = NodeIO.map(%{key: "val"})
      assert {:ok, _json} = Jason.encode(io)
    end

    test "Jason encoding works for object type" do
      io = NodeIO.object(%{score: 0.9}, %{"type" => "object"})
      assert {:ok, _json} = Jason.encode(io)
    end
  end
end
