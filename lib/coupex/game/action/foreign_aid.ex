defmodule Coupex.Game.Action.ForeignAid do
  @moduledoc false
  use Coupex.Game.Action

  alias Coupex.Game.Log

  def spec do
    %{
      id: "foreign_aid",
      label: "Foreign Aid",
      detail: "Take 2 coins",
      claim: nil,
      cost: 0,
      target: false
    }
  end

  def resolve(game, pending) do
    game
    |> Coupex.Game.resolve_income(pending.actor_id, 2)
    |> Log.log_action_resolution(pending, %{gained: 2})
  end
end
