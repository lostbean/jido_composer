defmodule TravelPlanner.Evaluator.Parse do
  @moduledoc """
  Pure parsing helpers for the TravelPlanner evaluator.

  Extracts structured data from the string formats used in plan maps and task structs.
  """

  @doc """
  Parse the Python-dict-syntax `local_constraint` string into a map.

  Input format: `"{'house rule': 'No smoking', 'cuisine': None, ...}"`
  Returns: `%{house_rule: "No smoking", cuisine: nil, room_type: nil, transportation: nil}`
  """
  @spec parse_local_constraint(String.t() | nil) :: %{
          house_rule: String.t() | nil,
          cuisine: String.t() | nil,
          room_type: String.t() | nil,
          transportation: String.t() | nil
        }
  def parse_local_constraint(nil), do: %{house_rule: nil, cuisine: nil, room_type: nil, transportation: nil}
  def parse_local_constraint(""), do: %{house_rule: nil, cuisine: nil, room_type: nil, transportation: nil}

  def parse_local_constraint(str) when is_binary(str) do
    %{
      house_rule: extract_constraint_value(str, "house rule"),
      cuisine: extract_cuisine_value(str),
      room_type: extract_constraint_value(str, "room type"),
      transportation: extract_constraint_value(str, "transportation")
    }
  end

  defp extract_constraint_value(str, key) do
    # Match 'key': 'value' or 'key': None or "key": "value" or "key": None
    pattern = ~r/'#{Regex.escape(key)}'\s*:\s*(?:'([^']*)'|"([^"]*)"|None|null)/

    case Regex.run(pattern, str) do
      [_, value] when value != "" -> value
      [_, "", value] when value != "" -> value
      _ -> nil
    end
  end

  # Cuisine can be a Python list ['Chinese', 'Mexican'] or a single string 'Indian' or None.
  # Always returns [String.t()] | nil to normalize the interface.
  defp extract_cuisine_value(str) do
    # Try Python list format first: 'cuisine': ['X', 'Y']
    list_pattern = ~r/'cuisine'\s*:\s*\[([^\]]*)\]/

    case Regex.run(list_pattern, str) do
      [_, items_str] ->
        items_str
        |> String.split(~r/,\s*/)
        |> Enum.map(fn item -> String.trim(item, "'") |> String.trim("\"") end)
        |> Enum.reject(&(&1 == ""))

      _ ->
        # Fall back to single value
        case extract_constraint_value(str, "cuisine") do
          nil -> nil
          value -> [value]
        end
    end
  end

  @doc """
  Parse the Python-list-syntax date string into a list of date strings.

  Input: `"['2022-03-13', '2022-03-14', '2022-03-15']"`
  Returns: `["2022-03-13", "2022-03-14", "2022-03-15"]`
  """
  @spec parse_dates(String.t() | [String.t()] | nil) :: [String.t()]
  def parse_dates(nil), do: []
  def parse_dates(dates) when is_list(dates), do: dates

  def parse_dates(str) when is_binary(str) do
    ~r/'(\d{4}-\d{2}-\d{2})'/
    |> Regex.scan(str)
    |> Enum.map(fn [_, date] -> date end)
  end

  @doc """
  Extract the monetary cost from a transport string.

  Handles: `"Flight F3927581, $89 (11:03-13:31)"` -> 89
  Handles: `"Self-driving, ... cost: $60"` -> 60
  Handles: `"Taxi, ... cost: $120"` -> 120
  Returns nil for "-" or unparseable strings.
  """
  @spec parse_transport_cost(String.t()) :: number() | nil
  def parse_transport_cost("-"), do: nil

  def parse_transport_cost(str) when is_binary(str) do
    case Regex.run(~r/\$(\d+(?:\.\d+)?)/, str) do
      [_, amount] -> parse_number(amount)
      _ -> nil
    end
  end

  @doc """
  Extract the restaurant name from a meal entry like `"Restaurant Name, City"`.

  Returns nil for `"-"`.
  """
  @spec parse_restaurant_name(String.t()) :: String.t() | nil
  def parse_restaurant_name("-"), do: nil

  def parse_restaurant_name(str) when is_binary(str) do
    # Name is everything before the last ", City" segment
    case String.split(str, ", ") do
      [_single] -> String.trim(str)
      parts -> parts |> Enum.slice(0..-2//1) |> Enum.join(", ") |> String.trim()
    end
  end

  @doc """
  Extract the restaurant city from a meal entry like `"Restaurant Name, City"`.

  Strips parenthetical state suffixes (e.g., `"Dallas(Texas)"` → `"Dallas"`) to
  match the Python reference evaluator's `get_valid_name_city` behavior.

  Returns nil for `"-"`.
  """
  @spec parse_restaurant_city(String.t()) :: String.t() | nil
  def parse_restaurant_city("-"), do: nil

  def parse_restaurant_city(str) when is_binary(str) do
    case String.split(str, ", ") do
      [_single] -> nil
      parts -> parts |> List.last() |> String.trim() |> strip_parenthetical()
    end
  end

  @doc """
  Extract the accommodation name from an entry like `"Hotel Name, City"`.

  Returns nil for `"-"`.
  """
  @spec parse_accommodation_name(String.t()) :: String.t() | nil
  def parse_accommodation_name("-"), do: nil

  def parse_accommodation_name(str) when is_binary(str) do
    case String.split(str, ", ") do
      [_single] -> String.trim(str)
      parts -> parts |> Enum.slice(0..-2//1) |> Enum.join(", ") |> String.trim()
    end
  end

  @doc """
  Extract the accommodation city from an entry like `"Hotel Name, City"`.

  Strips parenthetical state suffixes (e.g., `"Dallas(Texas)"` → `"Dallas"`) to
  match the Python reference evaluator's `get_valid_name_city` behavior.

  Returns nil for `"-"`.
  """
  @spec parse_accommodation_city(String.t()) :: String.t() | nil
  def parse_accommodation_city("-"), do: nil

  def parse_accommodation_city(str) when is_binary(str) do
    case String.split(str, ", ") do
      [_single] -> nil
      parts -> parts |> List.last() |> String.trim() |> strip_parenthetical()
    end
  end

  @doc """
  Strip a parenthetical suffix from a string. Matches the Python reference
  evaluator's `extract_before_parenthesis` behavior.

  `"Dallas(Texas)"` → `"Dallas"`
  `"Austin (New Mexico)"` → `"Austin"`
  `"Myrtle Beach"` → `"Myrtle Beach"`
  """
  @spec strip_parenthetical(String.t() | nil) :: String.t() | nil
  def strip_parenthetical(nil), do: nil

  def strip_parenthetical(str) when is_binary(str) do
    case Regex.run(~r/^(.*?)\s*\([^)]*\)/, str) do
      [_, before] -> String.trim(before)
      _ -> str
    end
  end

  @doc """
  Split an attraction field into individual attraction names.

  Input: `"SkyWheel Myrtle Beach; Broadway at the Beach"` -> `["SkyWheel Myrtle Beach", "Broadway at the Beach"]`
  Returns `[]` for `"-"`.
  """
  @spec parse_attractions(String.t()) :: [String.t()]
  def parse_attractions("-"), do: []

  def parse_attractions(str) when is_binary(str) do
    str
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Parse a `current_city` field.

  `"CityA to CityB"` -> `{:travel, "CityA", "CityB"}`
  `"CityA"` -> `{:stay, "CityA"}`
  """
  @spec parse_current_city(String.t()) :: {:stay, String.t()} | {:travel, String.t(), String.t()}
  def parse_current_city(str) when is_binary(str) do
    case String.split(str, " to ", parts: 2) do
      [from, to] -> {:travel, String.trim(from), String.trim(to)}
      [city] -> {:stay, String.trim(city)}
    end
  end

  @doc """
  Extract a flight number from a transport string.

  `"Flight F3927581, $89 (11:03-13:31)"` -> `"F3927581"`
  Returns nil for non-flight transport or "-".
  """
  @spec extract_flight_number(String.t()) :: String.t() | nil
  def extract_flight_number("-"), do: nil

  def extract_flight_number(str) when is_binary(str) do
    case Regex.run(~r/Flight\s+(\S+)/, str) do
      [_, number] ->
        # Strip trailing comma if present
        String.trim_trailing(number, ",")

      _ ->
        nil
    end
  end

  @doc """
  Detect transport mode from a transport string.

  Returns `:flight`, `:self_driving`, `:taxi`, or nil for "-".
  """
  @spec detect_transport_mode(String.t()) :: :flight | :self_driving | :taxi | nil
  def detect_transport_mode("-"), do: nil

  def detect_transport_mode(str) when is_binary(str) do
    str_down = String.downcase(str)

    cond do
      String.contains?(str_down, "flight") -> :flight
      String.contains?(str_down, "self-driv") -> :self_driving
      String.contains?(str_down, "taxi") -> :taxi
      true -> nil
    end
  end

  @doc """
  Extract origin and destination cities from a ground transport string.

  `"Self-driving, from City A to City B, ..."` -> `{"City A", "City B"}`
  Returns nil if not parseable.
  """
  @spec extract_ground_cities(String.t()) :: {String.t(), String.t()} | nil
  def extract_ground_cities(str) when is_binary(str) do
    case Regex.run(~r/from\s+(.+?)\s+to\s+(.+?)\s*,/, str) do
      [_, from, to] -> {String.trim(from), String.trim(to)}
      _ -> nil
    end
  end

  @doc "Parse a numeric string, returning integer or float."
  @spec parse_number(String.t()) :: number() | nil
  def parse_number(str) when is_binary(str) do
    trimmed = String.trim(str)

    case Integer.parse(trimmed) do
      {n, ""} -> n
      {n, "." <> rest} -> parse_float_from_parts(n, rest)
      _ -> nil
    end
  end

  def parse_number(_), do: nil

  defp parse_float_from_parts(integer_part, decimal_str) do
    case Float.parse("#{integer_part}.#{decimal_str}") do
      {f, ""} -> f
      _ -> nil
    end
  end

  @doc """
  Return the list of cities relevant for a given day's `current_city`.

  For a stay day, returns `[city]`. For a travel day, returns `[from, to]`.
  """
  @spec cities_for_day(String.t()) :: [String.t()]
  def cities_for_day(current_city) do
    case parse_current_city(current_city) do
      {:stay, city} -> [city]
      {:travel, from, to} -> [from, to]
    end
  end
end
