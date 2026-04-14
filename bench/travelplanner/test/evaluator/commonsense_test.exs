defmodule TravelPlanner.Evaluator.CommonsenseTest do
  use ExUnit.Case, async: true

  alias TravelPlanner.Evaluator.Commonsense
  alias TravelPlanner.ReferenceDB
  alias TravelPlanner.ReferenceDB.{Accommodation, Attraction, Flight, Restaurant}

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
      reference_information: %{}
    }

    struct!(TravelPlanner.Task, Map.merge(defaults, overrides))
  end

  defp make_db(overrides \\ %{}) do
    defaults = %{
      flights: %{},
      ground_transport: %{},
      accommodations: %{},
      attractions: %{},
      restaurants: %{}
    }

    struct!(ReferenceDB, Map.merge(defaults, overrides))
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
        "attraction" => "Aquarium; Boardwalk",
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
      flights: %{
        {"Washington", "Myrtle Beach", "2022-03-13"} => [
          %Flight{
            flight_number: "F001", origin: "Washington", destination: "Myrtle Beach",
            date: "2022-03-13", dep_time: "11:00", arr_time: "13:00",
            duration: "2h", price: 89, distance: 500
          }
        ],
        {"Myrtle Beach", "Washington", "2022-03-15"} => [
          %Flight{
            flight_number: "F002", origin: "Myrtle Beach", destination: "Washington",
            date: "2022-03-15", dep_time: "11:00", arr_time: "13:00",
            duration: "2h", price: 87, distance: 500
          }
        ]
      },
      restaurants: %{
        "Myrtle Beach" => [
          %Restaurant{name: "Crab Shack", city: "Myrtle Beach", cuisines: ["Seafood"], average_cost: 30, aggregate_rating: 4.0},
          %Restaurant{name: "Pier Restaurant", city: "Myrtle Beach", cuisines: ["American"], average_cost: 25, aggregate_rating: 3.5},
          %Restaurant{name: "Morning Cafe", city: "Myrtle Beach", cuisines: ["Cafe"], average_cost: 15, aggregate_rating: 4.2},
          %Restaurant{name: "Sushi Place", city: "Myrtle Beach", cuisines: ["Japanese"], average_cost: 35, aggregate_rating: 4.5},
          %Restaurant{name: "Steak House", city: "Myrtle Beach", cuisines: ["American"], average_cost: 40, aggregate_rating: 4.0},
          %Restaurant{name: "Bagel Shop", city: "Myrtle Beach", cuisines: ["Bakery"], average_cost: 10, aggregate_rating: 3.8}
        ]
      },
      attractions: %{
        "Myrtle Beach" => [
          %Attraction{name: "SkyWheel", city: "Myrtle Beach", address: nil, latitude: nil, longitude: nil, phone: nil, website: nil},
          %Attraction{name: "Aquarium", city: "Myrtle Beach", address: nil, latitude: nil, longitude: nil, phone: nil, website: nil},
          %Attraction{name: "Boardwalk", city: "Myrtle Beach", address: nil, latitude: nil, longitude: nil, phone: nil, website: nil},
          %Attraction{name: "Beach Park", city: "Myrtle Beach", address: nil, latitude: nil, longitude: nil, phone: nil, website: nil}
        ]
      },
      accommodations: %{
        "Myrtle Beach" => [
          %Accommodation{
            name: "Beach Hotel", city: "Myrtle Beach", price: 120,
            room_type: "Private room", minimum_nights: 1, maximum_occupancy: 2,
            review_rate: 4.5, house_rules: ["No smoking"]
          }
        ]
      }
    })
  end

  # ── is_valid_plan_length ────────────────────────────────────────────────

  describe "is_valid_plan_length/3" do
    test "passes when plan length matches task days" do
      assert :ok == Commonsense.is_valid_plan_length(sample_plan(), make_task(), make_db())
    end

    test "fails when plan is shorter" do
      plan = Enum.take(sample_plan(), 2)
      assert {:fail, reason} = Commonsense.is_valid_plan_length(plan, make_task(), make_db())
      assert reason =~ "expected 3 days, got 2"
    end

    test "fails when plan is longer" do
      plan = sample_plan() ++ [%{"days" => 4}]
      assert {:fail, reason} = Commonsense.is_valid_plan_length(plan, make_task(), make_db())
      assert reason =~ "expected 3 days, got 4"
    end
  end

  # ── is_reasonable_visiting_city ─────────────────────────────────────────

  describe "is_reasonable_visiting_city/3" do
    test "passes for valid round trip" do
      assert :ok == Commonsense.is_reasonable_visiting_city(sample_plan(), make_task(), make_db())
    end

    test "fails when trip doesn't start at origin" do
      plan = List.update_at(sample_plan(), 0, &Map.put(&1, "current_city", "Chicago to Myrtle Beach"))
      assert {:fail, reason} = Commonsense.is_reasonable_visiting_city(plan, make_task(), make_db())
      assert reason =~ "doesn't start at origin"
    end

    test "fails when trip doesn't end at origin" do
      plan = List.update_at(sample_plan(), 2, &Map.put(&1, "current_city", "Myrtle Beach to Chicago"))
      assert {:fail, reason} = Commonsense.is_reasonable_visiting_city(plan, make_task(), make_db())
      assert reason =~ "doesn't end at origin"
    end

    test "fails when plan visits unauthorized city" do
      plan = List.update_at(sample_plan(), 1, &Map.put(&1, "current_city", "Chicago"))
      assert {:fail, reason} = Commonsense.is_reasonable_visiting_city(plan, make_task(), make_db())
      assert reason =~ "Chicago"
    end

    test "passes when staying at origin" do
      plan = [%{"days" => 1, "current_city" => "Washington"}]
      task = make_task(%{days: 1, dest: "Washington"})
      assert :ok == Commonsense.is_reasonable_visiting_city(plan, task, make_db())
    end
  end

  # ── is_valid_transportation ─────────────────────────────────────────────

  describe "is_valid_transportation/3" do
    test "passes for valid flight-only plan" do
      assert :ok == Commonsense.is_valid_transportation(sample_plan(), make_task(), sample_db())
    end

    test "fails when flight and self-driving are mixed" do
      plan =
        sample_plan()
        |> List.update_at(0, &Map.put(&1, "transportation", "Self-driving, from Washington to Myrtle Beach, duration: 8h, distance: 600 km, cost: $60"))

      assert {:fail, reason} = Commonsense.is_valid_transportation(plan, make_task(), sample_db())
      assert reason =~ "mixes flight and self-driving"
    end

    test "fails when flight doesn't exist in DB" do
      plan =
        sample_plan()
        |> List.update_at(0, &Map.put(&1, "transportation", "Flight F999, $89 (11:00-13:00)"))

      assert {:fail, reason} = Commonsense.is_valid_transportation(plan, make_task(), sample_db())
      assert reason =~ "F999"
    end

    test "passes when all transport entries are absent" do
      plan = Enum.map(sample_plan(), &Map.put(&1, "transportation", "-"))
      assert :ok == Commonsense.is_valid_transportation(plan, make_task(), sample_db())
    end

    test "taxi does not conflict with flight" do
      plan =
        sample_plan()
        |> List.update_at(1, &Map.put(&1, "transportation", "Taxi, from Myrtle Beach to Myrtle Beach, duration: 0h, distance: 5 km, cost: $15"))

      db = Map.update!(sample_db(), :ground_transport, fn gt ->
        Map.put(gt, {"Myrtle Beach", "Myrtle Beach"}, %{self_driving: nil, taxi: %ReferenceDB.GroundTransport{
          mode: :taxi, origin: "Myrtle Beach", destination: "Myrtle Beach",
          duration: "0h", distance_km: 5, cost: 15
        }})
      end)

      assert :ok == Commonsense.is_valid_transportation(plan, make_task(), db)
    end
  end

  # ── is_valid_information_in_current_city ────────────────────────────────

  describe "is_valid_information_in_current_city/3" do
    test "passes when all entities exist in their cities" do
      assert :ok == Commonsense.is_valid_information_in_current_city(sample_plan(), make_task(), sample_db())
    end

    test "fails when restaurant not in city DB" do
      plan =
        sample_plan()
        |> List.update_at(0, &Map.put(&1, "lunch", "Unknown Place, Myrtle Beach"))

      assert {:fail, reason} = Commonsense.is_valid_information_in_current_city(plan, make_task(), sample_db())
      assert reason =~ "Unknown Place"
    end

    test "fails when attraction not in city DB" do
      plan =
        sample_plan()
        |> List.update_at(0, &Map.put(&1, "attraction", "NonExistent Attraction"))

      assert {:fail, reason} = Commonsense.is_valid_information_in_current_city(plan, make_task(), sample_db())
      assert reason =~ "NonExistent Attraction"
    end

    test "fails when accommodation not in city DB" do
      plan =
        sample_plan()
        |> List.update_at(0, &Map.put(&1, "accommodation", "Fake Hotel, Myrtle Beach"))

      assert {:fail, reason} = Commonsense.is_valid_information_in_current_city(plan, make_task(), sample_db())
      assert reason =~ "Fake Hotel"
    end

    test "skips absent entries" do
      plan =
        sample_plan()
        |> List.update_at(0, &Map.merge(&1, %{"breakfast" => "-", "lunch" => "-"}))

      assert :ok == Commonsense.is_valid_information_in_current_city(plan, make_task(), sample_db())
    end
  end

  # ── is_valid_restaurants ────────────────────────────────────────────────

  describe "is_valid_restaurants/3" do
    test "passes when no duplicates" do
      assert :ok == Commonsense.is_valid_restaurants(sample_plan(), make_task(), make_db())
    end

    test "fails when restaurant appears twice" do
      plan =
        sample_plan()
        |> List.update_at(1, &Map.put(&1, "breakfast", "Crab Shack, Myrtle Beach"))

      assert {:fail, reason} = Commonsense.is_valid_restaurants(plan, make_task(), make_db())
      assert reason =~ "Crab Shack"
    end

    test "skips absent entries" do
      plan = [
        %{"days" => 1, "breakfast" => "-", "lunch" => "-", "dinner" => "-"},
        %{"days" => 2, "breakfast" => "-", "lunch" => "-", "dinner" => "-"}
      ]

      assert :ok == Commonsense.is_valid_restaurants(plan, make_task(%{days: 2}), make_db())
    end
  end

  # ── is_valid_attractions ────────────────────────────────────────────────

  describe "is_valid_attractions/3" do
    test "passes when no duplicates" do
      assert :ok == Commonsense.is_valid_attractions(sample_plan(), make_task(), make_db())
    end

    test "fails when attraction appears twice" do
      plan =
        sample_plan()
        |> List.update_at(2, &Map.put(&1, "attraction", "SkyWheel"))

      assert {:fail, reason} = Commonsense.is_valid_attractions(plan, make_task(), make_db())
      assert reason =~ "SkyWheel"
    end

    test "handles multi-attraction fields" do
      plan = [
        %{"days" => 1, "attraction" => "A; B"},
        %{"days" => 2, "attraction" => "B; C"}
      ]

      assert {:fail, reason} = Commonsense.is_valid_attractions(plan, make_task(%{days: 2}), make_db())
      assert reason =~ "B"
    end
  end

  # ── is_valid_accommodation ─────────────────────────────────────────────

  describe "is_valid_accommodation/3" do
    test "passes when all non-last days have accommodation" do
      assert :ok == Commonsense.is_valid_accommodation(sample_plan(), make_task(), sample_db())
    end

    test "fails when non-last day missing accommodation" do
      plan =
        sample_plan()
        |> List.update_at(0, &Map.put(&1, "accommodation", "-"))

      assert {:fail, reason} = Commonsense.is_valid_accommodation(plan, make_task(), sample_db())
      assert reason =~ "missing accommodation"
    end

    test "last day can be absent" do
      plan =
        sample_plan()
        |> List.update_at(2, &Map.put(&1, "accommodation", "-"))

      assert :ok == Commonsense.is_valid_accommodation(plan, make_task(), sample_db())
    end

    test "fails when minimum_nights not met" do
      db = make_db(%{
        accommodations: %{
          "Myrtle Beach" => [
            %Accommodation{
              name: "Beach Hotel", city: "Myrtle Beach", price: 120,
              room_type: "Private room", minimum_nights: 3, maximum_occupancy: 2,
              review_rate: 4.5, house_rules: []
            }
          ]
        }
      })

      assert {:fail, reason} = Commonsense.is_valid_accommodation(sample_plan(), make_task(), db)
      assert reason =~ "minimum 3 nights"
    end
  end

  # ── is_not_absent ──────────────────────────────────────────────────────

  describe "is_not_absent/3" do
    test "passes when majority of slots are filled" do
      assert :ok == Commonsense.is_not_absent(sample_plan(), make_task(), make_db())
    end

    test "fails when more than half are absent" do
      plan = [
        %{"days" => 1, "breakfast" => "-", "lunch" => "-", "dinner" => "-",
          "attraction" => "-", "transportation" => "-", "accommodation" => "-"},
        %{"days" => 2, "breakfast" => "-", "lunch" => "-", "dinner" => "-",
          "attraction" => "-", "transportation" => "-", "accommodation" => "-"}
      ]

      assert {:fail, reason} = Commonsense.is_not_absent(plan, make_task(%{days: 2}), make_db())
      assert reason =~ "too many absent"
    end

    test "passes at exactly 50% absent" do
      plan = [
        %{"days" => 1, "breakfast" => "A, City", "lunch" => "B, City", "dinner" => "C, City",
          "attraction" => "-", "transportation" => "-", "accommodation" => "-"},
        %{"days" => 2, "breakfast" => "-", "lunch" => "-", "dinner" => "-",
          "attraction" => "X", "transportation" => "Flight F1, $10 (1:00-2:00)", "accommodation" => "H, City"}
      ]

      # 6 filled, 6 absent = 50% absent, should pass (<= 0.5)
      assert :ok == Commonsense.is_not_absent(plan, make_task(%{days: 2}), make_db())
    end
  end

  # ── check_all ──────────────────────────────────────────────────────────

  describe "check_all/3" do
    test "returns :ok when all constraints pass" do
      assert :ok == Commonsense.check_all(sample_plan(), make_task(), sample_db())
    end

    test "returns first failure with constraint name" do
      plan = Enum.take(sample_plan(), 2)
      assert {:fail, :is_valid_plan_length, _reason} = Commonsense.check_all(plan, make_task(), sample_db())
    end
  end
end
