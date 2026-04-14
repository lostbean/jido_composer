defmodule TravelPlanner.ReferenceDB do
  @moduledoc """
  Per-task reference data: flights, ground transport, restaurants, hotels, attractions.

  Built from `TravelPlanner.ReferenceInfo.parse/1` applied to a task's
  decoded `reference_information` map. All lookups are pure, return lists or
  maps, never raise on missing data.
  """

  alias TravelPlanner.ReferenceDB.{Accommodation, Attraction, Flight, GroundTransport, Restaurant}

  @enforce_keys [:flights, :ground_transport, :accommodations, :attractions, :restaurants]
  defstruct flights: %{},
            ground_transport: %{},
            accommodations: %{},
            attractions: %{},
            restaurants: %{}

  @type city :: String.t()
  @type date :: String.t()

  @type t :: %__MODULE__{
          flights: %{optional({city(), city(), date()}) => [Flight.t()]},
          ground_transport: %{
            optional({city(), city()}) => %{
              self_driving: GroundTransport.t() | nil,
              taxi: GroundTransport.t() | nil
            }
          },
          accommodations: %{optional(city()) => [Accommodation.t()]},
          attractions: %{optional(city()) => [Attraction.t()]},
          restaurants: %{optional(city()) => [Restaurant.t()]}
        }

  defmodule Flight do
    @moduledoc "A single flight between two cities on a given date."
    @enforce_keys [
      :flight_number,
      :origin,
      :destination,
      :date,
      :dep_time,
      :arr_time,
      :duration,
      :price,
      :distance
    ]
    defstruct [
      :flight_number,
      :origin,
      :destination,
      :date,
      :dep_time,
      :arr_time,
      :duration,
      :price,
      :distance
    ]

    @type t :: %__MODULE__{
            flight_number: String.t(),
            origin: String.t(),
            destination: String.t(),
            date: String.t(),
            dep_time: String.t(),
            arr_time: String.t(),
            duration: String.t() | nil,
            price: number() | nil,
            distance: number() | nil
          }
  end

  defmodule GroundTransport do
    @moduledoc "A self-driving or taxi route between two cities."
    @enforce_keys [:mode, :origin, :destination, :duration, :distance_km, :cost]
    defstruct [:mode, :origin, :destination, :duration, :distance_km, :cost]

    @type mode :: :self_driving | :taxi
    @type t :: %__MODULE__{
            mode: mode(),
            origin: String.t(),
            destination: String.t(),
            duration: String.t() | nil,
            distance_km: integer() | nil,
            cost: integer() | nil
          }
  end

  defmodule Accommodation do
    @moduledoc "A lodging option in a city."
    @enforce_keys [
      :name,
      :city,
      :price,
      :room_type,
      :minimum_nights,
      :maximum_occupancy,
      :review_rate,
      :house_rules
    ]
    defstruct [
      :name,
      :city,
      :price,
      :room_type,
      :minimum_nights,
      :maximum_occupancy,
      :review_rate,
      :house_rules
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            city: String.t(),
            price: number() | nil,
            room_type: String.t() | nil,
            minimum_nights: number() | nil,
            maximum_occupancy: integer() | nil,
            review_rate: number() | nil,
            house_rules: [String.t()]
          }
  end

  defmodule Attraction do
    @moduledoc "A tourist attraction in a city."
    @enforce_keys [:name, :city, :address, :latitude, :longitude, :phone, :website]
    defstruct [:name, :city, :address, :latitude, :longitude, :phone, :website]

    @type t :: %__MODULE__{
            name: String.t(),
            city: String.t(),
            address: String.t() | nil,
            latitude: float() | nil,
            longitude: float() | nil,
            phone: String.t() | nil,
            website: String.t() | nil
          }
  end

  defmodule Restaurant do
    @moduledoc "A restaurant in a city."
    @enforce_keys [:name, :city, :cuisines, :average_cost, :aggregate_rating]
    defstruct [:name, :city, :cuisines, :average_cost, :aggregate_rating]

    @type t :: %__MODULE__{
            name: String.t(),
            city: String.t(),
            cuisines: [String.t()],
            average_cost: number() | nil,
            aggregate_rating: number() | nil
          }
  end

  @empty_ground %{self_driving: nil, taxi: nil}

  @doc "Return the parsed flights for a given origin/destination/date, or `[]`."
  @spec flights_for(t(), String.t(), String.t(), String.t()) :: [Flight.t()]
  def flights_for(%__MODULE__{flights: flights}, origin, destination, date)
      when is_binary(origin) and is_binary(destination) and is_binary(date) do
    Map.get(flights, {origin, destination, date}, [])
  end

  @doc """
  Return the self-driving/taxi entries for a given origin/destination. Missing
  arms default to `nil`.
  """
  @spec ground_transport_for(t(), String.t(), String.t()) :: %{
          self_driving: GroundTransport.t() | nil,
          taxi: GroundTransport.t() | nil
        }
  def ground_transport_for(%__MODULE__{ground_transport: ground}, origin, destination)
      when is_binary(origin) and is_binary(destination) do
    Map.get(ground, {origin, destination}, @empty_ground)
  end

  @doc "Return the accommodations listed for a city, or `[]`."
  @spec accommodations_in(t(), String.t()) :: [Accommodation.t()]
  def accommodations_in(%__MODULE__{accommodations: accommodations}, city) when is_binary(city) do
    Map.get(accommodations, city, [])
  end

  @doc "Return the attractions listed for a city, or `[]`."
  @spec attractions_in(t(), String.t()) :: [Attraction.t()]
  def attractions_in(%__MODULE__{attractions: attractions}, city) when is_binary(city) do
    Map.get(attractions, city, [])
  end

  @doc "Return the restaurants listed for a city, or `[]`."
  @spec restaurants_in(t(), String.t()) :: [Restaurant.t()]
  def restaurants_in(%__MODULE__{restaurants: restaurants}, city) when is_binary(city) do
    Map.get(restaurants, city, [])
  end

  @doc """
  Return the sorted union of cities that appear as a key in
  accommodations, attractions, or restaurants.
  """
  @spec cities_with_data(t()) :: [String.t()]
  def cities_with_data(%__MODULE__{
        accommodations: accommodations,
        attractions: attractions,
        restaurants: restaurants
      }) do
    [accommodations, attractions, restaurants]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
