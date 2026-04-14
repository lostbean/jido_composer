defmodule TravelPlanner.RunnerTest do
  use ExUnit.Case, async: true

  alias TravelPlanner.Runner

  describe "parse_opts/1" do
    test "parses valid --split val" do
      assert {:ok, opts} = Runner.parse_opts(["--split", "val"])
      assert opts.split == :validation
      assert opts.limit == nil
      assert opts.offset == 0
      assert is_binary(opts.output)
    end

    test "parses --split validation" do
      assert {:ok, opts} = Runner.parse_opts(["--split", "validation"])
      assert opts.split == :validation
    end

    test "parses --split train" do
      assert {:ok, opts} = Runner.parse_opts(["--split", "train"])
      assert opts.split == :train
    end

    test "parses --split test" do
      assert {:ok, opts} = Runner.parse_opts(["--split", "test"])
      assert opts.split == :test
    end

    test "parses all options" do
      assert {:ok, opts} =
               Runner.parse_opts([
                 "--split",
                 "val",
                 "--limit",
                 "10",
                 "--offset",
                 "5",
                 "--output",
                 "results/custom"
               ])

      assert opts.split == :validation
      assert opts.limit == 10
      assert opts.offset == 5
      assert opts.output == "results/custom"
    end

    test "parses short aliases" do
      assert {:ok, opts} = Runner.parse_opts(["-s", "val", "-l", "3", "-o", "out"])
      assert opts.split == :validation
      assert opts.limit == 3
      assert opts.output == "out"
    end

    test "errors on missing --split" do
      assert {:error, msg} = Runner.parse_opts([])
      assert msg =~ "--split is required"
    end

    test "errors on unknown split value" do
      assert {:error, msg} = Runner.parse_opts(["--split", "bogus"])
      assert msg =~ "unknown split"
    end

    test "errors on unknown options" do
      assert {:error, msg} = Runner.parse_opts(["--split", "val", "--bogus", "x"])
      assert msg =~ "unknown options"
    end

    test "default output dir contains split label and timestamp" do
      assert {:ok, opts} = Runner.parse_opts(["--split", "val"])
      assert opts.output =~ "results/val-"
    end

    test "default offset is 0" do
      assert {:ok, opts} = Runner.parse_opts(["--split", "train"])
      assert opts.offset == 0
    end
  end
end
