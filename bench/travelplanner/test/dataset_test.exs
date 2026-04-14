defmodule TravelPlanner.DatasetTest do
  use ExUnit.Case, async: false

  @moduletag :network

  alias TravelPlanner.Dataset
  alias TravelPlanner.Task, as: TPTask

  test "load(:validation) returns 180 well-formed tasks" do
    tasks = Dataset.load(:validation)

    assert is_list(tasks)
    assert length(tasks) == 180
    assert Enum.all?(tasks, &match?(%TPTask{}, &1))

    Enum.each(tasks, fn task ->
      assert is_binary(task.query) and task.query != ""
      refute is_nil(task.reference_information)
    end)

    indexes = Enum.map(tasks, & &1.idx)
    assert indexes == Enum.to_list(0..179)
  end
end
