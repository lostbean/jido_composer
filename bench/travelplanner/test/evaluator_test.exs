defmodule TravelPlanner.EvaluatorTest do
  use ExUnit.Case, async: true

  alias TravelPlanner.Evaluator
  alias TravelPlanner.Evaluator.Parse
  alias TravelPlanner.Test.DFHelper

  # ── Parse module tests ─────────────────────────────────────────────────

  describe "Parse.parse_local_constraint/1" do
    test "parses all-None constraint" do
      input = "{'house rule': None, 'cuisine': None, 'room type': None, 'transportation': None}"

      assert %{house_rule: nil, cuisine: nil, room_type: nil, transportation: nil} ==
               Parse.parse_local_constraint(input)
    end

    test "parses constraint with values" do
      input = "{'house rule': 'No smoking', 'cuisine': 'Indian', 'room type': 'not shared room', 'transportation': 'no flight'}"

      assert %{
               house_rule: "No smoking",
               cuisine: ["Indian"],
               room_type: "not shared room",
               transportation: "no flight"
             } == Parse.parse_local_constraint(input)
    end

    test "handles nil input" do
      assert %{house_rule: nil, cuisine: nil, room_type: nil, transportation: nil} ==
               Parse.parse_local_constraint(nil)
    end

    test "handles empty string" do
      assert %{house_rule: nil, cuisine: nil, room_type: nil, transportation: nil} ==
               Parse.parse_local_constraint("")
    end

    test "handles mixed values and None" do
      input = "{'house rule': 'No parties', 'cuisine': None, 'room type': 'Private room', 'transportation': None}"

      assert %{house_rule: "No parties", cuisine: nil, room_type: "Private room", transportation: nil} ==
               Parse.parse_local_constraint(input)
    end

    test "parses cuisine as list (Python list format)" do
      input = "{'house rule': None, 'cuisine': ['Chinese', 'Mexican'], 'room type': None, 'transportation': None}"

      result = Parse.parse_local_constraint(input)
      assert result.cuisine == ["Chinese", "Mexican"]
    end

    test "parses single cuisine string as list" do
      input = "{'house rule': None, 'cuisine': 'Indian', 'room type': None, 'transportation': None}"

      result = Parse.parse_local_constraint(input)
      assert result.cuisine == ["Indian"]
    end
  end

  describe "Parse.parse_dates/1" do
    test "parses Python list syntax" do
      assert ["2022-03-13", "2022-03-14", "2022-03-15"] ==
               Parse.parse_dates("['2022-03-13', '2022-03-14', '2022-03-15']")
    end

    test "handles nil" do
      assert [] == Parse.parse_dates(nil)
    end

    test "passes through lists" do
      assert ["2022-03-13"] == Parse.parse_dates(["2022-03-13"])
    end
  end

  describe "Parse.parse_transport_cost/1" do
    test "extracts cost from flight string" do
      assert 89 == Parse.parse_transport_cost("Flight F3927581, $89 (11:03-13:31)")
    end

    test "extracts cost from self-driving string" do
      assert 60 == Parse.parse_transport_cost("Self-driving, from City A to City B, duration: 5h 30min, distance: 450 km, cost: $60")
    end

    test "returns nil for absent" do
      assert nil == Parse.parse_transport_cost("-")
    end
  end

  describe "Parse.parse_restaurant_name/1" do
    test "extracts name before city" do
      assert "Catfish Charlie's" == Parse.parse_restaurant_name("Catfish Charlie's, Myrtle Beach")
    end

    test "handles name with commas" do
      assert "A, B Restaurant" == Parse.parse_restaurant_name("A, B Restaurant, City")
    end

    test "returns nil for absent" do
      assert nil == Parse.parse_restaurant_name("-")
    end
  end

  describe "Parse.parse_restaurant_city/1 parenthetical stripping" do
    test "strips parenthetical state suffix" do
      assert "Dallas" == Parse.parse_restaurant_city("Joe's Diner, Dallas(Texas)")
    end

    test "leaves plain city names untouched" do
      assert "Myrtle Beach" == Parse.parse_restaurant_city("Catfish Charlie's, Myrtle Beach")
    end

    test "handles multi-word state in parentheses" do
      assert "Austin" == Parse.parse_restaurant_city("Test, Austin(New Mexico)")
    end
  end

  describe "Parse.parse_accommodation_city/1 parenthetical stripping" do
    test "strips parenthetical state suffix" do
      assert "Dallas" == Parse.parse_accommodation_city("Cozy Home, Dallas(Texas)")
    end

    test "leaves plain city names untouched" do
      assert "Myrtle Beach" == Parse.parse_accommodation_city("Beachside, Myrtle Beach")
    end
  end

  describe "Parse.strip_parenthetical/1" do
    test "strips parenthetical suffix" do
      assert "Dallas" == Parse.strip_parenthetical("Dallas(Texas)")
    end

    test "leaves string with no parenthesis untouched" do
      assert "Myrtle Beach" == Parse.strip_parenthetical("Myrtle Beach")
    end

    test "strips and trims" do
      assert "Austin" == Parse.strip_parenthetical("Austin (New Mexico)")
    end

    test "handles nil" do
      assert nil == Parse.strip_parenthetical(nil)
    end
  end

  describe "Parse.parse_accommodation_name/1" do
    test "extracts accommodation name" do
      assert "A WONDERFUL Place is Waiting 4U in Brooklyn!!!" ==
               Parse.parse_accommodation_name("A WONDERFUL Place is Waiting 4U in Brooklyn!!!, Myrtle Beach")
    end

    test "returns nil for absent" do
      assert nil == Parse.parse_accommodation_name("-")
    end
  end

  describe "Parse.parse_attractions/1" do
    test "splits on semicolons" do
      assert ["SkyWheel Myrtle Beach", "Broadway at the Beach"] ==
               Parse.parse_attractions("SkyWheel Myrtle Beach; Broadway at the Beach")
    end

    test "single attraction" do
      assert ["SkyWheel"] == Parse.parse_attractions("SkyWheel")
    end

    test "returns empty for absent" do
      assert [] == Parse.parse_attractions("-")
    end
  end

  describe "Parse.parse_current_city/1" do
    test "parses travel day" do
      assert {:travel, "Washington", "Myrtle Beach"} ==
               Parse.parse_current_city("Washington to Myrtle Beach")
    end

    test "parses stay day" do
      assert {:stay, "Myrtle Beach"} == Parse.parse_current_city("Myrtle Beach")
    end
  end

  describe "Parse.extract_flight_number/1" do
    test "extracts from flight string" do
      assert "F3927581" == Parse.extract_flight_number("Flight F3927581, $89 (11:03-13:31)")
    end

    test "returns nil for non-flight" do
      assert nil == Parse.extract_flight_number("Self-driving, from A to B, cost: $60")
    end

    test "returns nil for absent" do
      assert nil == Parse.extract_flight_number("-")
    end
  end

  describe "Parse.detect_transport_mode/1" do
    test "detects flight" do
      assert :flight == Parse.detect_transport_mode("Flight F001, $89 (11:00-13:00)")
    end

    test "detects self-driving" do
      assert :self_driving == Parse.detect_transport_mode("Self-driving, from A to B, cost: $60")
    end

    test "detects taxi" do
      assert :taxi == Parse.detect_transport_mode("Taxi, from A to B, cost: $30")
    end

    test "returns nil for absent" do
      assert nil == Parse.detect_transport_mode("-")
    end
  end

  # ── Integration: score_plan with the M6 cassette plan ──────────────────

  describe "score_plan/3 integration" do
    test "scores a well-formed plan as passing" do
      plan = m6_plan()
      task = m6_task()
      db = m6_db()

      result = Evaluator.score_plan(plan, task, db)

      case result do
        {:pass, details} ->
          assert length(details.commonsense) == 8
          assert length(details.hard) == 5

        {:fail, constraint, reason} ->
          flunk("Expected pass, but failed on #{constraint}: #{reason}")
      end
    end

    test "score_plan_detailed returns full report" do
      plan = m6_plan()
      task = m6_task()
      db = m6_db()

      report = Evaluator.score_plan_detailed(plan, task, db)

      assert is_boolean(report.passed)
      assert length(report.commonsense) == 8
      assert is_float(report.commonsense_pass_rate)
      assert is_float(report.total_pass_rate)
    end
  end

  # ── M6 cassette plan fixture ───────────────────────────────────────────

  defp m6_plan do
    [
      %{
        "days" => 1,
        "current_city" => "Washington to Myrtle Beach",
        "transportation" => "Flight F3927581, $89 (11:03-13:31)",
        "breakfast" => "-",
        "attraction" => "SkyWheel Myrtle Beach",
        "lunch" => "Catfish Charlie's, Myrtle Beach",
        "dinner" => "First Eat, Myrtle Beach",
        "accommodation" => "A WONDERFUL Place is Waiting 4U in Brooklyn!!!, Myrtle Beach"
      },
      %{
        "days" => 2,
        "current_city" => "Myrtle Beach",
        "transportation" => "-",
        "breakfast" => "La Pino'z Pizza, Myrtle Beach",
        "attraction" => "Ripley's Aquarium of Myrtle Beach; Broadway at the Beach",
        "lunch" => "Nagai, Myrtle Beach",
        "dinner" => "Twigly, Myrtle Beach",
        "accommodation" => "A WONDERFUL Place is Waiting 4U in Brooklyn!!!, Myrtle Beach"
      },
      %{
        "days" => 3,
        "current_city" => "Myrtle Beach to Washington",
        "transportation" => "Flight F3791200, $87 (11:36-13:06)",
        "breakfast" => "d' Curry House, Myrtle Beach",
        "attraction" => "Myrtle Beach Boardwalk and Promenade",
        "lunch" => "-",
        "dinner" => "-",
        "accommodation" => "-"
      }
    ]
  end

  defp m6_task do
    %TravelPlanner.Task{
      idx: 0,
      split: :validation,
      org: "Washington",
      dest: "Myrtle Beach",
      days: 3,
      date: "['2022-03-13', '2022-03-14', '2022-03-15']",
      level: "easy",
      query: "Please help me plan a trip from Washington to Myrtle Beach spanning 3 days.",
      reference_information: %{},
      local_constraint:
        "{'house rule': None, 'cuisine': None, 'room type': None, 'transportation': None}",
      people_number: 1,
      budget: 1400
    }
  end

  defp m6_db do
    DFHelper.make_db(%{
      flights:
        DFHelper.flights_df([
          [
            flight_number: "F3927581",
            origin: "Washington",
            destination: "Myrtle Beach",
            date: "2022-03-13",
            dep_time: "11:03",
            arr_time: "13:31",
            duration: "148 min",
            price: 89.0,
            distance: 487.0
          ],
          [
            flight_number: "F3791200",
            origin: "Myrtle Beach",
            destination: "Washington",
            date: "2022-03-15",
            dep_time: "11:36",
            arr_time: "13:06",
            duration: "90 min",
            price: 87.0,
            distance: 487.0
          ]
        ]),
      restaurants:
        DFHelper.restaurants_df([
          [name: "Catfish Charlie's", city: "Myrtle Beach", cuisines: "Seafood", average_cost: 20.0, aggregate_rating: 3.5],
          [name: "First Eat", city: "Myrtle Beach", cuisines: "Indian", average_cost: 15.0, aggregate_rating: 4.0],
          [name: "La Pino'z Pizza", city: "Myrtle Beach", cuisines: "Italian|Pizza", average_cost: 20.0, aggregate_rating: 4.0],
          [name: "Nagai", city: "Myrtle Beach", cuisines: "Japanese", average_cost: 25.0, aggregate_rating: 4.5],
          [name: "Twigly", city: "Myrtle Beach", cuisines: "Indian", average_cost: 15.0, aggregate_rating: 3.5],
          [name: "d' Curry House", city: "Myrtle Beach", cuisines: "Indian", average_cost: 10.0, aggregate_rating: 3.0]
        ]),
      attractions:
        DFHelper.attractions_df([
          [name: "SkyWheel Myrtle Beach", city: "Myrtle Beach", address: nil, latitude: nil, longitude: nil, phone: nil, website: nil],
          [name: "Ripley's Aquarium of Myrtle Beach", city: "Myrtle Beach", address: nil, latitude: nil, longitude: nil, phone: nil, website: nil],
          [name: "Broadway at the Beach", city: "Myrtle Beach", address: nil, latitude: nil, longitude: nil, phone: nil, website: nil],
          [name: "Myrtle Beach Boardwalk and Promenade", city: "Myrtle Beach", address: nil, latitude: nil, longitude: nil, phone: nil, website: nil]
        ]),
      accommodations:
        DFHelper.accommodations_df([
          [
            name: "A WONDERFUL Place is Waiting 4U in Brooklyn!!!",
            city: "Myrtle Beach",
            price: 73.0,
            room_type: "Private room",
            minimum_nights: 1.0,
            maximum_occupancy: 2,
            review_rate: 4.5,
            house_rules: "No smoking"
          ]
        ])
    })
  end
end
