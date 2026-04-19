defmodule TravelPlanner.Test.DFHelper do
  @moduledoc """
  Helper for constructing DataFrame-backed ReferenceDB instances in tests.
  """

  alias Explorer.DataFrame, as: DF
  alias Explorer.Series, as: S
  alias TravelPlanner.ReferenceDB

  @doc """
  Build a ReferenceDB with empty DataFrames, optionally overriding specific tables.

  ## Examples

      make_db()
      make_db(%{restaurants: restaurants_df([...])})
  """
  def make_db(overrides \\ %{}) do
    defaults = %{
      flights: empty_flights_df(),
      ground_transport: empty_ground_transport_df(),
      accommodations: empty_accommodations_df(),
      attractions: empty_attractions_df(),
      restaurants: empty_restaurants_df()
    }

    struct!(ReferenceDB, Map.merge(defaults, overrides))
  end

  @doc "Build a flights DataFrame from a list of keyword/maps."
  def flights_df(rows) when is_list(rows) do
    if rows == [] do
      empty_flights_df()
    else
      DF.new(normalize_rows(rows, flight_columns()))
    end
  end

  @doc "Build a ground_transport DataFrame from a list of keyword/maps."
  def ground_transport_df(rows) when is_list(rows) do
    if rows == [] do
      empty_ground_transport_df()
    else
      DF.new(normalize_rows(rows, ground_transport_columns()))
    end
  end

  @doc "Build an accommodations DataFrame from a list of keyword/maps."
  def accommodations_df(rows) when is_list(rows) do
    if rows == [] do
      empty_accommodations_df()
    else
      DF.new(normalize_rows(rows, accommodation_columns()))
    end
  end

  @doc "Build an attractions DataFrame from a list of keyword/maps."
  def attractions_df(rows) when is_list(rows) do
    if rows == [] do
      empty_attractions_df()
    else
      DF.new(normalize_rows(rows, attraction_columns()))
    end
  end

  @doc "Build a restaurants DataFrame from a list of keyword/maps."
  def restaurants_df(rows) when is_list(rows) do
    if rows == [] do
      empty_restaurants_df()
    else
      DF.new(normalize_rows(rows, restaurant_columns()))
    end
  end

  # ── Empty DataFrame constructors with correct schemas ──

  def empty_flights_df do
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

  def empty_ground_transport_df do
    DF.new(
      mode: S.from_list([], dtype: :string),
      origin: S.from_list([], dtype: :string),
      destination: S.from_list([], dtype: :string),
      duration: S.from_list([], dtype: :string),
      distance_km: S.from_list([], dtype: {:s, 64}),
      cost: S.from_list([], dtype: {:s, 64})
    )
  end

  def empty_accommodations_df do
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

  def empty_attractions_df do
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

  def empty_restaurants_df do
    DF.new(
      name: S.from_list([], dtype: :string),
      city: S.from_list([], dtype: :string),
      cuisines: S.from_list([], dtype: :string),
      average_cost: S.from_list([], dtype: {:f, 64}),
      aggregate_rating: S.from_list([], dtype: {:f, 64})
    )
  end

  # ── Column definitions ──

  defp flight_columns do
    [:flight_number, :origin, :destination, :date, :dep_time, :arr_time, :duration, :price, :distance]
  end

  defp ground_transport_columns do
    [:mode, :origin, :destination, :duration, :distance_km, :cost]
  end

  defp accommodation_columns do
    [:name, :city, :price, :room_type, :minimum_nights, :maximum_occupancy, :review_rate, :house_rules]
  end

  defp attraction_columns do
    [:name, :city, :address, :latitude, :longitude, :phone, :website]
  end

  defp restaurant_columns do
    [:name, :city, :cuisines, :average_cost, :aggregate_rating]
  end

  # Normalize a list of keyword lists or maps to column-oriented data for DF.new
  defp normalize_rows(rows, columns) do
    Map.new(columns, fn col ->
      {col, Enum.map(rows, fn row ->
        case row do
          kw when is_list(kw) -> Keyword.get(kw, col)
          map when is_map(map) -> Map.get(map, col)
        end
      end)}
    end)
  end
end
