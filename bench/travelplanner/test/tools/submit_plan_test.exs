defmodule TravelPlanner.Tools.SubmitPlanTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Context
  alias TravelPlanner.Task, as: TPTask
  alias TravelPlanner.Tools.SubmitPlan

  defp minimal_task(days) do
    %TPTask{
      idx: 0,
      split: :validation,
      org: "Origin",
      dest: "Dest",
      days: days,
      date: ["2022-03-01"],
      level: "easy",
      query: "test",
      reference_information: ""
    }
  end

  defp day(idx, overrides \\ %{}) do
    base = %{
      "days" => idx,
      "current_city" => "City#{idx}",
      "transportation" => "-",
      "breakfast" => "-",
      "attraction" => "-",
      "lunch" => "-",
      "dinner" => "-",
      "accommodation" => "-"
    }

    Map.merge(base, overrides)
  end

  defp params(plan, task) do
    %{
      Context.ambient_key() => %{task: task},
      plan: plan
    }
  end

  describe "run/2" do
    test "accepts a well-formed 3-day plan and returns the normalized plan" do
      task = minimal_task(3)
      plan = Enum.map(1..3, &day/1)

      assert {:ok, %{plan: normalized}} = SubmitPlan.run(params(plan, task), %{})
      assert length(normalized) == 3
      assert Enum.all?(normalized, fn entry -> Map.has_key?(entry, "days") end)
      assert Enum.map(normalized, & &1["days"]) == [1, 2, 3]
    end

    test "rejects a plan whose length does not match task.days" do
      task = minimal_task(3)
      plan = Enum.map(1..2, &day/1)

      assert {:error, msg} = SubmitPlan.run(params(plan, task), %{})
      assert msg =~ "3 entries"
      assert msg =~ "got 2"
    end

    test "rejects a plan with a missing required key on some day" do
      task = minimal_task(3)

      plan = [
        day(1),
        day(2) |> Map.delete("lunch"),
        day(3)
      ]

      assert {:error, msg} = SubmitPlan.run(params(plan, task), %{})
      assert msg =~ "entry 2"
      assert msg =~ "missing"
      assert msg =~ "lunch"
    end

    test "rejects a plan whose day index does not match position" do
      task = minimal_task(3)

      plan = [
        day(1),
        day(2, %{"days" => 5}),
        day(3)
      ]

      assert {:error, msg} = SubmitPlan.run(params(plan, task), %{})
      assert msg =~ "entry 2"
      assert msg =~ "expected 2"
    end

    test "accepts atom-keyed entries by normalizing to strings" do
      task = minimal_task(2)

      plan = [
        %{
          days: 1,
          current_city: "CityA",
          transportation: "-",
          breakfast: "-",
          attraction: "-",
          lunch: "-",
          dinner: "-",
          accommodation: "-"
        },
        %{
          days: 2,
          current_city: "CityB",
          transportation: "-",
          breakfast: "-",
          attraction: "-",
          lunch: "-",
          dinner: "-",
          accommodation: "-"
        }
      ]

      assert {:ok, %{plan: normalized}} = SubmitPlan.run(params(plan, task), %{})
      assert Enum.all?(normalized, fn entry -> Map.has_key?(entry, "days") end)
      assert Enum.map(normalized, & &1["current_city"]) == ["CityA", "CityB"]
    end
  end
end
