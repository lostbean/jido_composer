defmodule TravelPlanner.Evaluator.HardTest do
  use ExUnit.Case, async: true

  alias TravelPlanner.Evaluator.Hard
  alias TravelPlanner.Test.DFHelper

  # ── helpers ──────────────────────────────────────────────────────────────

  defp make_task(overrides \\ %{}) do
    defaults = %{
      idx: 0,
      split: :validation,
      org: "Washington",
      dest: "Myrtle Beach",
      days: 3,
      date: "['2022-03-13', '2022-03-14', '2022-03-15']",
      level: "easy",
      query: "test query",
      reference_information: %{},
      local_constraint: "{'house rule': None, 'cuisine': None, 'room type': None, 'transportation': None}",
      people_number: 1,
      budget: 1400
    }

    struct!(TravelPlanner.Task, Map.merge(defaults, overrides))
  end

  defp make_db(overrides \\ %{}) do
    DFHelper.make_db(overrides)
  end

  defp sample_plan do
    [
      %{
        "days" => 1,
        "current_city" => "Washington to Myrtle Beach",
        "transportation" => "Flight F001, $89 (11:00-13:00)",
        "breakfast" => "-",
        "attraction" => "SkyWheel",
        "lunch" => "Crab Shack, Myrtle Beach",
        "dinner" => "Pier Restaurant, Myrtle Beach",
        "accommodation" => "Beach Hotel, Myrtle Beach"
      },
      %{
        "days" => 2,
        "current_city" => "Myrtle Beach",
        "transportation" => "-",
        "breakfast" => "Morning Cafe, Myrtle Beach",
        "attraction" => "Aquarium",
        "lunch" => "Sushi Place, Myrtle Beach",
        "dinner" => "Steak House, Myrtle Beach",
        "accommodation" => "Beach Hotel, Myrtle Beach"
      },
      %{
        "days" => 3,
        "current_city" => "Myrtle Beach to Washington",
        "transportation" => "Flight F002, $87 (11:00-13:00)",
        "breakfast" => "Bagel Shop, Myrtle Beach",
        "attraction" => "Beach Park",
        "lunch" => "-",
        "dinner" => "-",
        "accommodation" => "-"
      }
    ]
  end

  defp sample_db do
    make_db(%{
      restaurants:
        DFHelper.restaurants_df([
          [name: "Crab Shack", city: "Myrtle Beach", cuisines: "Seafood", average_cost: 30.0, aggregate_rating: 4.0],
          [name: "Pier Restaurant", city: "Myrtle Beach", cuisines: "American", average_cost: 25.0, aggregate_rating: 3.5],
          [name: "Morning Cafe", city: "Myrtle Beach", cuisines: "Indian|Cafe", average_cost: 15.0, aggregate_rating: 4.2],
          [name: "Sushi Place", city: "Myrtle Beach", cuisines: "Japanese", average_cost: 35.0, aggregate_rating: 4.5],
          [name: "Steak House", city: "Myrtle Beach", cuisines: "American", average_cost: 40.0, aggregate_rating: 4.0],
          [name: "Bagel Shop", city: "Myrtle Beach", cuisines: "Bakery", average_cost: 10.0, aggregate_rating: 3.8]
        ]),
      accommodations:
        DFHelper.accommodations_df([
          [
            name: "Beach Hotel",
            city: "Myrtle Beach",
            price: 120.0,
            room_type: "Private room",
            minimum_nights: 1.0,
            maximum_occupancy: 2,
            review_rate: 4.5,
            house_rules: "No smoking|No parties"
          ]
        ])
    })
  end

  # ── is_valid_cuisine ───────────────────────────────────────────────────

  describe "is_valid_cuisine/3" do
    test "passes when no cuisine constraint" do
      assert :ok == Hard.is_valid_cuisine(sample_plan(), make_task(), sample_db())
    end

    test "passes when required cuisine is present" do
      task = make_task(%{
        local_constraint: "{'house rule': None, 'cuisine': 'Indian', 'room type': None, 'transportation': None}"
      })

      assert :ok == Hard.is_valid_cuisine(sample_plan(), task, sample_db())
    end

    test "fails when required cuisine not found" do
      task = make_task(%{
        local_constraint: "{'house rule': None, 'cuisine': 'Mexican', 'room type': None, 'transportation': None}"
      })

      assert {:fail, reason} = Hard.is_valid_cuisine(sample_plan(), task, sample_db())
      assert reason =~ "Mexican"
    end

    test "cuisine matching is case-insensitive" do
      task = make_task(%{
        local_constraint: "{'house rule': None, 'cuisine': 'indian', 'room type': None, 'transportation': None}"
      })

      assert :ok == Hard.is_valid_cuisine(sample_plan(), task, sample_db())
    end

    test "passes when multiple required cuisines are all satisfied" do
      # Plan has Indian (Morning Cafe) and Seafood (Crab Shack)
      task = make_task(%{
        local_constraint: "{'house rule': None, 'cuisine': ['Indian', 'Seafood'], 'room type': None, 'transportation': None}"
      })

      assert :ok == Hard.is_valid_cuisine(sample_plan(), task, sample_db())
    end

    test "fails when one of multiple required cuisines is not satisfied" do
      # Plan has Indian but not Mexican
      task = make_task(%{
        local_constraint: "{'house rule': None, 'cuisine': ['Indian', 'Mexican'], 'room type': None, 'transportation': None}"
      })

      assert {:fail, reason} = Hard.is_valid_cuisine(sample_plan(), task, sample_db())
      assert reason =~ "Mexican"
    end

    test "skips restaurants in origin city" do
      # Add a restaurant in Washington (origin) that serves Mexican
      db = make_db(%{
        restaurants:
          DFHelper.restaurants_df([
            [name: "Crab Shack", city: "Myrtle Beach", cuisines: "Seafood", average_cost: 30.0, aggregate_rating: 4.0],
            [name: "Morning Cafe", city: "Myrtle Beach", cuisines: "Indian", average_cost: 15.0, aggregate_rating: 4.2],
            [name: "DC Tacos", city: "Washington", cuisines: "Mexican", average_cost: 20.0, aggregate_rating: 4.0]
          ])
      })

      # Plan references DC Tacos in origin city — should NOT count toward Mexican cuisine
      plan = [
        %{
          "days" => 1,
          "current_city" => "Washington to Myrtle Beach",
          "transportation" => "Flight F001, $89 (11:00-13:00)",
          "breakfast" => "DC Tacos, Washington",
          "attraction" => "Beach",
          "lunch" => "Crab Shack, Myrtle Beach",
          "dinner" => "Morning Cafe, Myrtle Beach",
          "accommodation" => "Hotel, Myrtle Beach"
        },
        %{
          "days" => 2,
          "current_city" => "Myrtle Beach to Washington",
          "transportation" => "Flight F002, $87 (11:00-13:00)",
          "breakfast" => "-",
          "attraction" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "accommodation" => "-"
        }
      ]

      task = make_task(%{
        days: 2,
        local_constraint: "{'house rule': None, 'cuisine': ['Mexican'], 'room type': None, 'transportation': None}"
      })

      assert {:fail, reason} = Hard.is_valid_cuisine(plan, task, db)
      assert reason =~ "Mexican"
    end
  end

  # ── is_valid_room_rule ─────────────────────────────────────────────────

  describe "is_valid_room_rule/3" do
    test "passes when no house rule constraint" do
      assert :ok == Hard.is_valid_room_rule(sample_plan(), make_task(), sample_db())
    end

    test "passes when accommodation does not prohibit the required activity" do
      task = make_task(%{
        local_constraint: "{'house rule': 'pets', 'cuisine': None, 'room type': None, 'transportation': None}"
      })

      assert :ok == Hard.is_valid_room_rule(sample_plan(), task, sample_db())
    end

    test "fails when accommodation prohibits the required activity" do
      task = make_task(%{
        local_constraint: "{'house rule': 'smoking', 'cuisine': None, 'room type': None, 'transportation': None}"
      })

      assert {:fail, reason} = Hard.is_valid_room_rule(sample_plan(), task, sample_db())
      assert reason =~ "smoking"
    end
  end

  # ── is_valid_room_type ─────────────────────────────────────────────────

  describe "is_valid_room_type/3" do
    test "passes when no room type constraint" do
      assert :ok == Hard.is_valid_room_type(sample_plan(), make_task(), sample_db())
    end

    test "passes when room type matches" do
      task = make_task(%{
        local_constraint: "{'house rule': None, 'cuisine': None, 'room type': 'Private room', 'transportation': None}"
      })

      assert :ok == Hard.is_valid_room_type(sample_plan(), task, sample_db())
    end

    test "fails when room type doesn't match" do
      task = make_task(%{
        local_constraint: "{'house rule': None, 'cuisine': None, 'room type': 'Entire home/apt', 'transportation': None}"
      })

      assert {:fail, reason} = Hard.is_valid_room_type(sample_plan(), task, sample_db())
      assert reason =~ "room type"
    end

    test "handles negated constraint" do
      task = make_task(%{
        local_constraint: "{'house rule': None, 'cuisine': None, 'room type': 'not shared room', 'transportation': None}"
      })

      # Beach Hotel is "Private room", not "shared room", so should pass
      assert :ok == Hard.is_valid_room_type(sample_plan(), task, sample_db())
    end

    test "negated constraint fails when room type matches the excluded type" do
      db = make_db(%{
        accommodations:
          DFHelper.accommodations_df([
            [
              name: "Beach Hotel",
              city: "Myrtle Beach",
              price: 120.0,
              room_type: "Shared room",
              minimum_nights: 1.0,
              maximum_occupancy: 4,
              review_rate: 3.0,
              house_rules: ""
            ]
          ])
      })

      task = make_task(%{
        local_constraint: "{'house rule': None, 'cuisine': None, 'room type': 'not shared room', 'transportation': None}"
      })

      assert {:fail, _reason} = Hard.is_valid_room_type(sample_plan(), task, db)
    end
  end

  # ── is_valid_transportation_mode ───────────────────────────────────────

  describe "is_valid_transportation_mode/3" do
    test "passes when no transportation constraint" do
      assert :ok == Hard.is_valid_transportation_mode(sample_plan(), make_task(), make_db())
    end

    test "fails when no-flight constraint but plan has flights" do
      task = make_task(%{
        local_constraint: "{'house rule': None, 'cuisine': None, 'room type': None, 'transportation': 'no flight'}"
      })

      assert {:fail, reason} = Hard.is_valid_transportation_mode(sample_plan(), task, make_db())
      assert reason =~ "no flight"
    end

    test "passes when no-flight constraint and plan uses self-driving" do
      task = make_task(%{
        local_constraint: "{'house rule': None, 'cuisine': None, 'room type': None, 'transportation': 'no flight'}"
      })

      plan =
        sample_plan()
        |> List.update_at(0, &Map.put(&1, "transportation", "Self-driving, from Washington to Myrtle Beach, duration: 8h, distance: 600 km, cost: $60"))
        |> List.update_at(2, &Map.put(&1, "transportation", "Self-driving, from Myrtle Beach to Washington, duration: 8h, distance: 600 km, cost: $60"))

      assert :ok == Hard.is_valid_transportation_mode(plan, task, make_db())
    end

    test "passes when self-driving required and plan uses it" do
      task = make_task(%{
        local_constraint: "{'house rule': None, 'cuisine': None, 'room type': None, 'transportation': 'self-driving'}"
      })

      plan =
        sample_plan()
        |> List.update_at(0, &Map.put(&1, "transportation", "Self-driving, from Washington to Myrtle Beach, duration: 8h, distance: 600 km, cost: $60"))
        |> List.update_at(2, &Map.put(&1, "transportation", "Self-driving, from Myrtle Beach to Washington, duration: 8h, distance: 600 km, cost: $60"))

      assert :ok == Hard.is_valid_transportation_mode(plan, task, make_db())
    end
  end

  # ── is_valid_cost ──────────────────────────────────────────────────────

  describe "is_valid_cost/3" do
    test "passes when total cost within budget (1 person)" do
      # Flights: 89 + 87 = 176 (* 1 person = 176)
      # Accommodation: 120 * 2 nights * ceil(1/2) = 120 * 2 * 1 = 240
      # Restaurants: (30 + 25 + 15 + 35 + 40 + 10) * 1 = 155
      # Total: 176 + 240 + 155 = 571, budget = 1400
      assert :ok == Hard.is_valid_cost(sample_plan(), make_task(), sample_db())
    end

    test "fails when total cost exceeds budget" do
      task = make_task(%{budget: 100})
      assert {:fail, reason} = Hard.is_valid_cost(sample_plan(), task, sample_db())
      assert reason =~ "exceeds budget"
    end

    test "multiplies restaurant costs by people_number" do
      # With 10 people, restaurants: 155 * 10 = 1550, already over 1400 budget
      task = make_task(%{people_number: 10, budget: 1400})
      assert {:fail, _reason} = Hard.is_valid_cost(sample_plan(), task, sample_db())
    end

    test "multiplies flight costs by people_number" do
      # Flight costs: (89 + 87) * 3 people = 528
      # Accommodation: 120 * 2 nights * ceil(3/2) = 120 * 2 * 2 = 480
      # Restaurants: 155 * 3 = 465
      # Total: 528 + 480 + 465 = 1473
      task = make_task(%{people_number: 3, budget: 1472})
      assert {:fail, _reason} = Hard.is_valid_cost(sample_plan(), task, sample_db())

      task_ok = make_task(%{people_number: 3, budget: 1473})
      assert :ok == Hard.is_valid_cost(sample_plan(), task_ok, sample_db())
    end

    test "scales self-driving cost by ceil(people/5)" do
      plan = [
        %{
          "days" => 1,
          "current_city" => "A to B",
          "transportation" => "Self-driving, from A to B, duration: 5h, distance: 300 km, cost: $100",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "-",
          "accommodation" => "-"
        }
      ]

      # 6 people: ceil(6/5) = 2 cars, cost = 100 * 2 = 200
      task = make_task(%{days: 1, people_number: 6, budget: 199})
      assert {:fail, _} = Hard.is_valid_cost(plan, task, make_db())

      task_ok = make_task(%{days: 1, people_number: 6, budget: 200})
      assert :ok == Hard.is_valid_cost(plan, task_ok, make_db())
    end

    test "scales taxi cost by ceil(people/4)" do
      plan = [
        %{
          "days" => 1,
          "current_city" => "A to B",
          "transportation" => "Taxi, from A to B, duration: 5h, distance: 300 km, cost: $100",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "-",
          "accommodation" => "-"
        }
      ]

      # 5 people: ceil(5/4) = 2 taxis, cost = 100 * 2 = 200
      task = make_task(%{days: 1, people_number: 5, budget: 199})
      assert {:fail, _} = Hard.is_valid_cost(plan, task, make_db())

      task_ok = make_task(%{days: 1, people_number: 5, budget: 200})
      assert :ok == Hard.is_valid_cost(plan, task_ok, make_db())
    end

    test "scales accommodation by ceil(people/max_occupancy)" do
      # max_occupancy=2, 3 people → ceil(3/2) = 2 rooms, price = 120 * 2 = 240 per night
      # 2 nights → 480
      task = make_task(%{people_number: 3, budget: 480})

      plan = [
        %{
          "days" => 1, "current_city" => "Myrtle Beach",
          "transportation" => "-", "breakfast" => "-", "lunch" => "-",
          "dinner" => "-", "attraction" => "-",
          "accommodation" => "Beach Hotel, Myrtle Beach"
        },
        %{
          "days" => 2, "current_city" => "Myrtle Beach",
          "transportation" => "-", "breakfast" => "-", "lunch" => "-",
          "dinner" => "-", "attraction" => "-",
          "accommodation" => "Beach Hotel, Myrtle Beach"
        }
      ]

      # Cost = 120 * ceil(3/2) * 2 nights = 120 * 2 * 2 = 480
      assert :ok == Hard.is_valid_cost(plan, task, sample_db())

      task_tight = make_task(%{people_number: 3, budget: 479})
      assert {:fail, _} = Hard.is_valid_cost(plan, task_tight, sample_db())
    end

    test "passes when no budget set" do
      task = make_task(%{budget: nil})
      assert :ok == Hard.is_valid_cost(sample_plan(), task, sample_db())
    end

    test "absent entries contribute zero cost" do
      plan = [
        %{"days" => 1, "transportation" => "-", "breakfast" => "-", "lunch" => "-",
          "dinner" => "-", "attraction" => "-", "accommodation" => "-"}
      ]

      task = make_task(%{days: 1, budget: 0})
      assert :ok == Hard.is_valid_cost(plan, task, make_db())
    end
  end

  # ── check_all ──────────────────────────────────────────────────────────

  describe "check_all/3" do
    test "returns :ok when all constraints pass" do
      assert :ok == Hard.check_all(sample_plan(), make_task(), sample_db())
    end

    test "returns first failure" do
      task = make_task(%{budget: 100})
      assert {:fail, :is_valid_cost, _reason} = Hard.check_all(sample_plan(), task, sample_db())
    end
  end
end
