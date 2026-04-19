defmodule TravelPlanner.PostProcessTest do
  use ExUnit.Case, async: true

  alias TravelPlanner.PostProcess
  alias TravelPlanner.Test.DFHelper

  defp default_task do
    %TravelPlanner.Task{
      idx: 1,
      split: :validation,
      org: "New York",
      dest: "Chicago",
      days: 3,
      date: ["2024-01-10", "2024-01-11", "2024-01-12"],
      level: "easy",
      query: "test query",
      reference_information: "{}",
      people_number: 1,
      budget: 2000,
      local_constraint: nil
    }
  end

  defp default_db do
    DFHelper.make_db(%{
      restaurants:
        DFHelper.restaurants_df([
          [name: "Lou Malnati's Pizzeria", city: "Chicago", cuisines: "Italian", average_cost: 30.0, aggregate_rating: 4.5],
          [name: "Portillo's Hot Dogs", city: "Chicago", cuisines: "American", average_cost: 15.0, aggregate_rating: 4.0],
          [name: "Girl & The Goat", city: "Chicago", cuisines: "American", average_cost: 50.0, aggregate_rating: 4.7],
          [name: "Al's Italian Beef", city: "Chicago", cuisines: "Italian", average_cost: 12.0, aggregate_rating: 4.2],
          [name: "Smoque BBQ", city: "Chicago", cuisines: "BBQ", average_cost: 25.0, aggregate_rating: 4.6]
        ]),
      accommodations:
        DFHelper.accommodations_df([
          [
            name: "A WONDERFUL Place is Waiting 4U in Brooklyn!!!",
            city: "Chicago",
            price: 200.0,
            room_type: "Entire home/apt",
            minimum_nights: 1.0,
            maximum_occupancy: 4,
            review_rate: 4.5,
            house_rules: "No smoking"
          ],
          [
            name: "Budget Inn Chicago",
            city: "Chicago",
            price: 80.0,
            room_type: "Private room",
            minimum_nights: 1.0,
            maximum_occupancy: 2,
            review_rate: 3.5,
            house_rules: "No smoking"
          ]
        ]),
      attractions:
        DFHelper.attractions_df([
          [name: "Millennium Park", city: "Chicago", address: "201 E Randolph St", latitude: 41.8826, longitude: -87.6226, phone: nil, website: nil],
          [name: "The Art Institute of Chicago", city: "Chicago", address: "111 S Michigan Ave", latitude: 41.8796, longitude: -87.6237, phone: nil, website: nil],
          [name: "Navy Pier", city: "Chicago", address: "600 E Grand Ave", latitude: 41.8917, longitude: -87.6086, phone: nil, website: nil]
        ])
    })
  end

  describe "fix/3 entity name normalization" do
    test "normalizes a slightly wrong restaurant name" do
      plan = [
        %{
          "days" => 1,
          "current_city" => "New York to Chicago",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "Lou Malnatis Pizzeria, Chicago",
          "dinner" => "Portillo's Hot Dogs, Chicago",
          "attraction" => "Millennium Park",
          "accommodation" => "A WONDERFUL Place is Waiting 4U in Brooklyn!!!, Chicago"
        },
        %{
          "days" => 2,
          "current_city" => "Chicago",
          "transportation" => "-",
          "breakfast" => "Girl & The Goat, Chicago",
          "lunch" => "Al's Italian Beef, Chicago",
          "dinner" => "Smoque BBQ, Chicago",
          "attraction" => "The Art Institute of Chicago",
          "accommodation" => "A WONDERFUL Place is Waiting 4U in Brooklyn!!!, Chicago"
        },
        %{
          "days" => 3,
          "current_city" => "Chicago to New York",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "-",
          "accommodation" => "-"
        }
      ]

      fixed = PostProcess.fix(plan, default_task(), default_db())

      # "Lou Malnatis Pizzeria" (missing apostrophe) should be normalized
      assert Map.get(Enum.at(fixed, 0), "lunch") == "Lou Malnati's Pizzeria, Chicago"
    end

    test "normalizes a truncated accommodation name" do
      plan = [
        %{
          "days" => 1,
          "current_city" => "New York to Chicago",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "-",
          "accommodation" => "A WONDERFUL Place is Waiting 4U in Brooklyn, Chicago"
        },
        %{
          "days" => 2,
          "current_city" => "Chicago",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "-",
          "accommodation" => "A WONDERFUL Place is Waiting 4U in Brooklyn, Chicago"
        },
        %{
          "days" => 3,
          "current_city" => "Chicago to New York",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "-",
          "accommodation" => "-"
        }
      ]

      fixed = PostProcess.fix(plan, default_task(), default_db())

      # Truncated name should match via substring
      assert Map.get(Enum.at(fixed, 0), "accommodation") ==
               "A WONDERFUL Place is Waiting 4U in Brooklyn!!!, Chicago"
    end

    test "normalizes a slightly wrong attraction name" do
      plan = [
        %{
          "days" => 1,
          "current_city" => "New York to Chicago",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "Art Institute of Chicago",
          "accommodation" => "-"
        },
        %{
          "days" => 2,
          "current_city" => "Chicago to New York",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "-",
          "accommodation" => "-"
        }
      ]

      fixed = PostProcess.fix(plan, default_task(), default_db())

      # "Art Institute of Chicago" should match "The Art Institute of Chicago" via fuzzy
      assert Map.get(Enum.at(fixed, 0), "attraction") == "The Art Institute of Chicago"
    end
  end

  describe "fix/3 restaurant deduplication" do
    test "replaces duplicate restaurant with cheapest alternative" do
      plan = [
        %{
          "days" => 1,
          "current_city" => "New York to Chicago",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "Lou Malnati's Pizzeria, Chicago",
          "dinner" => "Portillo's Hot Dogs, Chicago",
          "attraction" => "-",
          "accommodation" => "-"
        },
        %{
          "days" => 2,
          "current_city" => "Chicago",
          "transportation" => "-",
          "breakfast" => "Lou Malnati's Pizzeria, Chicago",
          "lunch" => "Girl & The Goat, Chicago",
          "dinner" => "-",
          "attraction" => "-",
          "accommodation" => "-"
        },
        %{
          "days" => 3,
          "current_city" => "Chicago to New York",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "-",
          "accommodation" => "-"
        }
      ]

      fixed = PostProcess.fix(plan, default_task(), default_db())

      # Day 1 keeps "Lou Malnati's Pizzeria"
      assert Map.get(Enum.at(fixed, 0), "lunch") == "Lou Malnati's Pizzeria, Chicago"

      # Day 2 breakfast should be replaced (it was a duplicate)
      day2_breakfast = Map.get(Enum.at(fixed, 1), "breakfast")
      refute day2_breakfast == "Lou Malnati's Pizzeria, Chicago"
      # Should be one of the remaining restaurants
      replacement_name = TravelPlanner.Evaluator.Parse.parse_restaurant_name(day2_breakfast)
      assert replacement_name in ["Al's Italian Beef", "Smoque BBQ"]
    end
  end

  describe "fix/3 attraction deduplication" do
    test "replaces duplicate attraction with alternative" do
      plan = [
        %{
          "days" => 1,
          "current_city" => "New York to Chicago",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "Millennium Park; Navy Pier",
          "accommodation" => "-"
        },
        %{
          "days" => 2,
          "current_city" => "Chicago",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "Millennium Park",
          "accommodation" => "-"
        },
        %{
          "days" => 3,
          "current_city" => "Chicago to New York",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "-",
          "accommodation" => "-"
        }
      ]

      fixed = PostProcess.fix(plan, default_task(), default_db())

      # Day 1 keeps Millennium Park
      day1_attractions = Map.get(Enum.at(fixed, 0), "attraction")
      assert day1_attractions =~ "Millennium Park"

      # Day 2 should have a replacement (not Millennium Park again)
      day2_attraction = Map.get(Enum.at(fixed, 1), "attraction")
      refute day2_attraction == "Millennium Park"
      assert day2_attraction == "The Art Institute of Chicago"
    end
  end

  describe "fix/3 budget enforcement" do
    test "downgrades accommodation when over budget" do
      task = %{default_task() | budget: 300, people_number: 1}

      plan = [
        %{
          "days" => 1,
          "current_city" => "New York to Chicago",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "Lou Malnati's Pizzeria, Chicago",
          "dinner" => "Portillo's Hot Dogs, Chicago",
          "attraction" => "-",
          "accommodation" =>
            "A WONDERFUL Place is Waiting 4U in Brooklyn!!!, Chicago"
        },
        %{
          "days" => 2,
          "current_city" => "Chicago",
          "transportation" => "-",
          "breakfast" => "Girl & The Goat, Chicago",
          "lunch" => "Al's Italian Beef, Chicago",
          "dinner" => "Smoque BBQ, Chicago",
          "attraction" => "-",
          "accommodation" =>
            "A WONDERFUL Place is Waiting 4U in Brooklyn!!!, Chicago"
        },
        %{
          "days" => 3,
          "current_city" => "Chicago to New York",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "-",
          "accommodation" => "-"
        }
      ]

      # Cost before fix: accommodation 200*2 = 400, meals = 30+15+50+12+25 = 132
      # Total = 532, budget = 300

      fixed = PostProcess.fix(plan, task, default_db())

      # After downgrade: accommodation should be Budget Inn Chicago (80*2 = 160)
      day1_acc = Map.get(Enum.at(fixed, 0), "accommodation")
      assert day1_acc == "Budget Inn Chicago, Chicago"

      # May also drop some meals if still over budget
      # Budget Inn: 160, if meals still 132 -> total 292, under 300
    end

    test "drops expensive meals when accommodation downgrade is insufficient" do
      task = %{default_task() | budget: 150, people_number: 1}

      plan = [
        %{
          "days" => 1,
          "current_city" => "New York to Chicago",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "Lou Malnati's Pizzeria, Chicago",
          "dinner" => "Girl & The Goat, Chicago",
          "attraction" => "-",
          "accommodation" => "Budget Inn Chicago, Chicago"
        },
        %{
          "days" => 2,
          "current_city" => "Chicago to New York",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "-",
          "accommodation" => "-"
        }
      ]

      # Cost: accommodation 80, meals 30+50 = 80, total = 160, budget = 150

      fixed = PostProcess.fix(plan, task, default_db())

      # Should drop the most expensive meal first (Girl & The Goat at 50)
      day1 = Enum.at(fixed, 0)

      # At least one meal should be dropped
      meals = [Map.get(day1, "lunch"), Map.get(day1, "dinner")]
      assert "-" in meals
    end
  end

  describe "fix/3 trip loop closure" do
    test "fixes last day to end at origin" do
      plan = [
        %{
          "days" => 1,
          "current_city" => "New York to Chicago",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "-",
          "accommodation" => "-"
        },
        %{
          "days" => 2,
          "current_city" => "Chicago",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "-",
          "accommodation" => "-"
        }
      ]

      fixed = PostProcess.fix(plan, default_task(), default_db())

      # Last day should end at New York
      last_day = List.last(fixed)
      assert Map.get(last_day, "current_city") == "Chicago to New York"
    end

    test "does not modify a plan that already ends at origin" do
      plan = [
        %{
          "days" => 1,
          "current_city" => "New York to Chicago",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "-",
          "accommodation" => "-"
        },
        %{
          "days" => 2,
          "current_city" => "Chicago to New York",
          "transportation" => "-",
          "breakfast" => "-",
          "lunch" => "-",
          "dinner" => "-",
          "attraction" => "-",
          "accommodation" => "-"
        }
      ]

      fixed = PostProcess.fix(plan, default_task(), default_db())

      assert Map.get(Enum.at(fixed, 1), "current_city") == "Chicago to New York"
    end
  end

  describe "jaro_winkler/2" do
    test "identical strings return 1.0" do
      assert PostProcess.jaro_winkler("hello", "hello") == 1.0
    end

    test "completely different strings return low score" do
      assert PostProcess.jaro_winkler("abc", "xyz") < 0.5
    end

    test "similar strings return high score" do
      score = PostProcess.jaro_winkler("lou malnatis pizzeria", "lou malnati's pizzeria")
      assert score > 0.9
    end
  end

  describe "find_best_match/2" do
    test "exact case-insensitive match" do
      assert PostProcess.find_best_match("millennium park", ["Millennium Park", "Navy Pier"]) ==
               "Millennium Park"
    end

    test "substring match" do
      assert PostProcess.find_best_match(
               "A WONDERFUL Place is Waiting 4U in Brooklyn",
               ["A WONDERFUL Place is Waiting 4U in Brooklyn!!!", "Budget Inn"]
             ) == "A WONDERFUL Place is Waiting 4U in Brooklyn!!!"
    end

    test "returns nil for no match" do
      assert PostProcess.find_best_match("Totally Unknown Place", ["Millennium Park"]) == nil
    end
  end
end
