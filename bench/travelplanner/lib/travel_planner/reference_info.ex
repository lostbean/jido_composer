defmodule TravelPlanner.ReferenceInfo do
  @moduledoc """
  Parses a task's decoded `reference_information` map into a
  `TravelPlanner.ReferenceDB{}` with Explorer DataFrames.

  The upstream reference blob uses dynamic top-level keys built from template
  strings (e.g. `"Accommodations in Myrtle Beach"`, `"Flight from X to Y on
  YYYY-MM-DD"`). This module recognises those prefixes, extracts the relevant
  city/date fragments, and accumulates rows into DataFrames.

  All errors are logged and swallowed — we prefer to return a partial DB
  over raising, so a single malformed row doesn't tank the whole benchmark.
  """

  require Logger

  alias Explorer.DataFrame, as: DF
  alias Explorer.Series, as: S
  alias TravelPlanner.ReferenceDB

  @flight_key_re ~r/^Flight from (.+) to (.+) on (\d{4}-\d{2}-\d{2})$/
  @ground_key_re ~r/^(Self-driving|Taxi) from (.+) to (.+)$/
  @ground_value_re ~r/duration:\s*(?<duration>.+?),\s*distance:\s*(?<distance>.+?),\s*cost:\s*(?<cost>.+?)$/

  @doc "Parse a task's decoded reference_information map into a ReferenceDB."
  @spec parse(map()) :: ReferenceDB.t()
  def parse(ref_info) when is_map(ref_info) do
    initial = %{flights: [], ground_transport: [], accommodations: [], attractions: [], restaurants: []}

    accumulated = Enum.reduce(ref_info, initial, &reduce_entry/2)

    %ReferenceDB{
      flights: build_flights_df(accumulated.flights),
      ground_transport: build_ground_transport_df(accumulated.ground_transport),
      accommodations: build_accommodations_df(accumulated.accommodations),
      attractions: build_attractions_df(accumulated.attractions),
      restaurants: build_restaurants_df(accumulated.restaurants)
    }
  end

  # ─── entry dispatch ──────────────────────────────────────────────────────

  defp reduce_entry({key, value}, acc) when is_binary(key) do
    cond do
      String.starts_with?(key, "Flight from ") ->
        handle_flight(key, value, acc)

      String.starts_with?(key, "Self-driving from ") ->
        handle_ground("self_driving", key, value, acc)

      String.starts_with?(key, "Taxi from ") ->
        handle_ground("taxi", key, value, acc)

      String.starts_with?(key, "Accommodations in ") ->
        handle_city_list(:accommodations, key, value, acc, "Accommodations in ")

      String.starts_with?(key, "Attractions in ") ->
        handle_city_list(:attractions, key, value, acc, "Attractions in ")

      String.starts_with?(key, "Restaurants in ") ->
        handle_city_list(:restaurants, key, value, acc, "Restaurants in ")

      true ->
        Logger.warning("TravelPlanner.ReferenceInfo: unknown reference key: #{inspect(key)}")
        acc
    end
  end

  defp reduce_entry({key, _value}, acc) do
    Logger.warning("TravelPlanner.ReferenceInfo: non-binary reference key: #{inspect(key)}")
    acc
  end

  # ─── flights ─────────────────────────────────────────────────────────────

  defp handle_flight(key, value, acc) do
    case Regex.run(@flight_key_re, key) do
      [_, origin, destination, date] ->
        rows = parse_flight_value(value, origin, destination, date)
        %{acc | flights: acc.flights ++ rows}

      _ ->
        Logger.warning("TravelPlanner.ReferenceInfo: unparseable flight key: #{inspect(key)}")
        acc
    end
  end

  defp parse_flight_value(value, origin, destination, date) when is_list(value) do
    Enum.map(value, &build_flight_row(&1, origin, destination, date))
  end

  defp parse_flight_value(value, _origin, _destination, _date) when is_binary(value), do: []

  defp parse_flight_value(value, origin, destination, date) do
    Logger.warning(
      "TravelPlanner.ReferenceInfo: unexpected flight value type for #{origin}->#{destination} on #{date}: #{inspect(value)}"
    )

    []
  end

  defp build_flight_row(record, origin, destination, date) when is_map(record) do
    %{
      flight_number: Map.get(record, "Flight Number"),
      origin: Map.get(record, "OriginCityName", origin),
      destination: Map.get(record, "DestCityName", destination),
      date: Map.get(record, "FlightDate", date),
      dep_time: Map.get(record, "DepTime"),
      arr_time: Map.get(record, "ArrTime"),
      duration: Map.get(record, "ActualElapsedTime"),
      price: to_float(Map.get(record, "Price")),
      distance: to_float(Map.get(record, "Distance"))
    }
  end

  # ─── ground transport ────────────────────────────────────────────────────

  defp handle_ground(mode, key, value, acc) do
    with [_, _prefix, origin, destination] <- Regex.run(@ground_key_re, key),
         {:ok, row} <- parse_ground_value(mode, origin, destination, value) do
      %{acc | ground_transport: [row | acc.ground_transport]}
    else
      nil ->
        Logger.warning("TravelPlanner.ReferenceInfo: unparseable ground key: #{inspect(key)}")
        acc

      {:error, reason} ->
        Logger.warning("TravelPlanner.ReferenceInfo: failed to parse ground value for #{inspect(key)}: #{reason}")
        acc
    end
  end

  defp parse_ground_value(mode, origin, destination, value) when is_binary(value) do
    case Regex.named_captures(@ground_value_re, value) do
      %{"duration" => duration, "distance" => distance, "cost" => cost} ->
        {:ok,
         %{
           mode: mode,
           origin: origin,
           destination: destination,
           duration: String.trim(duration),
           distance_km: parse_distance_km(distance),
           cost: parse_integer(cost)
         }}

      _ ->
        {:error, "no duration/distance/cost match"}
    end
  end

  defp parse_ground_value(_mode, _origin, _destination, value) do
    {:error, "expected string, got #{inspect(value)}"}
  end

  defp parse_distance_km(raw) when is_binary(raw) do
    raw
    |> String.trim()
    |> String.replace(~r/\s*km$/i, "")
    |> String.replace(",", "")
    |> parse_integer()
  end

  defp parse_integer(raw) when is_binary(raw) do
    case Integer.parse(String.trim(raw)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_integer(raw) when is_integer(raw), do: raw
  defp parse_integer(_), do: nil

  # ─── per-city lists ──────────────────────────────────────────────────────

  defp handle_city_list(kind, key, value, acc, prefix) do
    city = String.trim_leading(key, prefix)

    rows =
      case value do
        list when is_list(list) ->
          list
          |> Enum.map(&build_city_row(kind, &1, city))
          |> Enum.reject(&is_nil/1)

        other ->
          Logger.warning("TravelPlanner.ReferenceInfo: expected list for #{inspect(key)}, got #{inspect(other)}")
          []
      end

    %{acc | kind => acc[kind] ++ rows}
  end

  defp build_city_row(:accommodations, record, city) when is_map(record) do
    %{
      name: Map.get(record, "NAME"),
      city: city,
      price: to_float(Map.get(record, "price")),
      room_type: Map.get(record, "room type"),
      minimum_nights: to_float(Map.get(record, "minimum nights")),
      maximum_occupancy: Map.get(record, "maximum occupancy"),
      review_rate: to_float(Map.get(record, "review rate number")),
      house_rules: join_house_rules(Map.get(record, "house_rules"))
    }
  end

  defp build_city_row(:attractions, record, city) when is_map(record) do
    %{
      name: Map.get(record, "Name"),
      city: city,
      address: Map.get(record, "Address"),
      latitude: to_float(Map.get(record, "Latitude")),
      longitude: to_float(Map.get(record, "Longitude")),
      phone: Map.get(record, "Phone"),
      website: Map.get(record, "Website")
    }
  end

  defp build_city_row(:restaurants, record, city) when is_map(record) do
    %{
      name: Map.get(record, "Name"),
      city: city,
      cuisines: join_cuisines(Map.get(record, "Cuisines")),
      average_cost: to_float(Map.get(record, "Average Cost")),
      aggregate_rating: to_float(Map.get(record, "Aggregate Rating"))
    }
  end

  defp build_city_row(kind, record, city) do
    Logger.warning("TravelPlanner.ReferenceInfo: expected map for #{kind} record in #{city}, got #{inspect(record)}")
    nil
  end

  # ─── list column encoding (pipe-separated) ──────────────────────────────

  defp join_house_rules(nil), do: ""
  defp join_house_rules(""), do: ""

  defp join_house_rules(raw) when is_binary(raw) do
    raw
    |> String.split(" & ", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.join("|")
  end

  defp join_house_rules(other) do
    Logger.warning("TravelPlanner.ReferenceInfo: unexpected house_rules value: #{inspect(other)}")
    ""
  end

  defp join_cuisines(nil), do: ""
  defp join_cuisines(""), do: ""

  defp join_cuisines(raw) when is_binary(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.join("|")
  end

  defp join_cuisines(other) do
    Logger.warning("TravelPlanner.ReferenceInfo: unexpected cuisines value: #{inspect(other)}")
    ""
  end

  # ─── DataFrame construction ─────────────────────────────────────────────

  defp build_flights_df([]) do
    DF.new(
      flight_number: S.from_list([], dtype: :string),
      origin: S.from_list([], dtype: :string),
      destination: S.from_list([], dtype: :string),
      date: S.from_list([], dtype: :string),
      dep_time: S.from_list([], dtype: :string),
      arr_time: S.from_list([], dtype: :string),
      duration: S.from_list([], dtype: :string),
      price: S.from_list([], dtype: {:f, 64}),
      distance: S.from_list([], dtype: {:f, 64})
    )
  end

  defp build_flights_df(rows), do: DF.new(rows_to_columns(rows))

  defp build_ground_transport_df([]) do
    DF.new(
      mode: S.from_list([], dtype: :string),
      origin: S.from_list([], dtype: :string),
      destination: S.from_list([], dtype: :string),
      duration: S.from_list([], dtype: :string),
      distance_km: S.from_list([], dtype: {:s, 64}),
      cost: S.from_list([], dtype: {:s, 64})
    )
  end

  defp build_ground_transport_df(rows), do: DF.new(rows_to_columns(rows))

  defp build_accommodations_df([]) do
    DF.new(
      name: S.from_list([], dtype: :string),
      city: S.from_list([], dtype: :string),
      price: S.from_list([], dtype: {:f, 64}),
      room_type: S.from_list([], dtype: :string),
      minimum_nights: S.from_list([], dtype: {:f, 64}),
      maximum_occupancy: S.from_list([], dtype: {:s, 64}),
      review_rate: S.from_list([], dtype: {:f, 64}),
      house_rules: S.from_list([], dtype: :string)
    )
  end

  defp build_accommodations_df(rows), do: DF.new(rows_to_columns(rows))

  defp build_attractions_df([]) do
    DF.new(
      name: S.from_list([], dtype: :string),
      city: S.from_list([], dtype: :string),
      address: S.from_list([], dtype: :string),
      latitude: S.from_list([], dtype: {:f, 64}),
      longitude: S.from_list([], dtype: {:f, 64}),
      phone: S.from_list([], dtype: :string),
      website: S.from_list([], dtype: :string)
    )
  end

  defp build_attractions_df(rows), do: DF.new(rows_to_columns(rows))

  defp build_restaurants_df([]) do
    DF.new(
      name: S.from_list([], dtype: :string),
      city: S.from_list([], dtype: :string),
      cuisines: S.from_list([], dtype: :string),
      average_cost: S.from_list([], dtype: {:f, 64}),
      aggregate_rating: S.from_list([], dtype: {:f, 64})
    )
  end

  defp build_restaurants_df(rows), do: DF.new(rows_to_columns(rows))

  # Convert list-of-maps to column-oriented map-of-lists for DF.new
  defp rows_to_columns([first | _] = rows) do
    keys = Map.keys(first)

    Map.new(keys, fn key ->
      {key, Enum.map(rows, &Map.get(&1, key))}
    end)
  end

  # ─── helpers ─────────────────────────────────────────────────────────────

  defp to_float(nil), do: nil
  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, _} -> f
      :error -> nil
    end
  end
  defp to_float(_), do: nil
end
