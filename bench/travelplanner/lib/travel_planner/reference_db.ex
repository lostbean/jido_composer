defmodule TravelPlanner.ReferenceDB do
  @moduledoc """
  Per-task reference data: flights, ground transport, restaurants, hotels, attractions.

  Built from `TravelPlanner.ReferenceInfo.parse/1` applied to a task's
  decoded `reference_information` map. Stores data as Explorer DataFrames.
  All lookups are pure, return lists of atom-keyed maps or structured results,
  never raise on missing data.
  """

  alias Explorer.DataFrame, as: DF
  alias Explorer.Series, as: S
  alias TravelPlanner.ReferenceDB.Helpers

  @enforce_keys [:flights, :ground_transport, :accommodations, :attractions, :restaurants]
  defstruct flights: nil,
            ground_transport: nil,
            accommodations: nil,
            attractions: nil,
            restaurants: nil

  @type t :: %__MODULE__{
          flights: DF.t(),
          ground_transport: DF.t(),
          accommodations: DF.t(),
          attractions: DF.t(),
          restaurants: DF.t()
        }

  # ── Column schemas (for documentation and empty-DF construction) ──

  @flight_columns [:flight_number, :origin, :destination, :date, :dep_time, :arr_time, :duration, :price, :distance]
  @ground_transport_columns [:mode, :origin, :destination, :duration, :distance_km, :cost]
  @accommodation_columns [:name, :city, :price, :room_type, :minimum_nights, :maximum_occupancy, :review_rate, :house_rules]
  @attraction_columns [:name, :city, :address, :latitude, :longitude, :phone, :website]
  @restaurant_columns [:name, :city, :cuisines, :average_cost, :aggregate_rating]

  def flight_columns, do: @flight_columns
  def ground_transport_columns, do: @ground_transport_columns
  def accommodation_columns, do: @accommodation_columns
  def attraction_columns, do: @attraction_columns
  def restaurant_columns, do: @restaurant_columns

  # ── Query functions ──

  @doc "Return flights for a given origin/destination/date as a list of atom-keyed maps, or `[]`."
  @spec flights_for(t(), String.t(), String.t(), String.t()) :: [map()]
  def flights_for(%__MODULE__{flights: df}, origin, destination, date)
      when is_binary(origin) and is_binary(destination) and is_binary(date) do
    df
    |> DF.filter_with(fn ldf ->
      S.equal(ldf["origin"], origin)
      |> S.and(S.equal(ldf["destination"], destination))
      |> S.and(S.equal(ldf["date"], date))
    end)
    |> Helpers.to_maps()
  end

  @doc "Check if a flight number exists anywhere in the flights DataFrame."
  @spec has_flight_number?(t(), String.t()) :: boolean()
  def has_flight_number?(%__MODULE__{flights: df}, flight_number) when is_binary(flight_number) do
    df
    |> DF.filter_with(fn ldf -> S.equal(ldf["flight_number"], flight_number) end)
    |> DF.n_rows() > 0
  end

  @doc """
  Return the self-driving/taxi entries for a given origin/destination.
  Returns `%{self_driving: map() | nil, taxi: map() | nil}`.
  """
  @spec ground_transport_for(t(), String.t(), String.t()) :: %{
          self_driving: map() | nil,
          taxi: map() | nil
        }
  def ground_transport_for(%__MODULE__{ground_transport: df}, origin, destination)
      when is_binary(origin) and is_binary(destination) do
    filtered =
      df
      |> DF.filter_with(fn ldf ->
        S.equal(ldf["origin"], origin)
        |> S.and(S.equal(ldf["destination"], destination))
      end)
      |> Helpers.to_maps()

    sd = Enum.find(filtered, fn row -> row.mode == "self_driving" end)
    taxi = Enum.find(filtered, fn row -> row.mode == "taxi" end)

    %{self_driving: sd, taxi: taxi}
  end

  @doc "Return the accommodations listed for a city as atom-keyed maps, or `[]`."
  @spec accommodations_in(t(), String.t()) :: [map()]
  def accommodations_in(%__MODULE__{accommodations: df}, city) when is_binary(city) do
    df
    |> DF.filter_with(fn ldf -> S.equal(ldf["city"], city) end)
    |> Helpers.to_maps()
    |> Enum.map(&postprocess_accommodation/1)
  end

  @doc "Return the attractions listed for a city as atom-keyed maps, or `[]`."
  @spec attractions_in(t(), String.t()) :: [map()]
  def attractions_in(%__MODULE__{attractions: df}, city) when is_binary(city) do
    df
    |> DF.filter_with(fn ldf -> S.equal(ldf["city"], city) end)
    |> Helpers.to_maps()
  end

  @doc "Return the restaurants listed for a city as atom-keyed maps, or `[]`."
  @spec restaurants_in(t(), String.t()) :: [map()]
  def restaurants_in(%__MODULE__{restaurants: df}, city) when is_binary(city) do
    df
    |> DF.filter_with(fn ldf -> S.equal(ldf["city"], city) end)
    |> Helpers.to_maps()
    |> Enum.map(&postprocess_restaurant/1)
  end

  @doc """
  Return the sorted union of cities that appear in
  accommodations, attractions, or restaurants.
  """
  @spec cities_with_data(t()) :: [String.t()]
  def cities_with_data(%__MODULE__{
        accommodations: acc_df,
        attractions: attr_df,
        restaurants: rest_df
      }) do
    [acc_df["city"], attr_df["city"], rest_df["city"]]
    |> S.concat()
    |> S.distinct()
    |> S.sort()
    |> S.to_list()
  end

  # ── Post-processing (split pipe-separated list columns) ──

  defp postprocess_restaurant(row) do
    Map.update!(row, :cuisines, &Helpers.split_list_column/1)
  end

  defp postprocess_accommodation(row) do
    Map.update!(row, :house_rules, &Helpers.split_list_column/1)
  end
end
