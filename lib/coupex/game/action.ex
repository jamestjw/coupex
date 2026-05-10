defmodule Coupex.Game.Action do
  @moduledoc false

  @type t :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:detail) => String.t(),
          required(:claim) => atom() | nil,
          required(:cost) => non_neg_integer(),
          required(:target) => boolean()
        }

  @callback spec() :: t()
  @callback resolve(game :: Coupex.Game.t(), pending :: map()) :: Coupex.Game.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour Coupex.Game.Action
    end
  end

  @actions [
    Coupex.Game.Action.Income,
    Coupex.Game.Action.ForeignAid,
    Coupex.Game.Action.Tax,
    Coupex.Game.Action.Assassinate,
    Coupex.Game.Action.Steal,
    Coupex.Game.Action.Exchange,
    Coupex.Game.Action.Coup
  ]

  def all_modules, do: @actions

  def all_specs do
    Enum.map(@actions, & &1.spec())
  end

  def fetch_spec(action_id) do
    case Enum.find(all_specs(), &(&1.id == action_id)) do
      nil -> {:error, "Unknown action."}
      spec -> {:ok, spec}
    end
  end

  def module(action_id) do
    Enum.find(@actions, &(&1.spec().id == action_id))
  end
end
