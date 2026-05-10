defmodule Coupex.Game.Action.Tax do
  @moduledoc false
  use Coupex.Game.Action

  alias Coupex.Game.Log

  def spec do
    %{
      id: "tax",
      label: "Tax",
      detail: "Claim Duke for 3 coins",
      claim: :duke,
      cost: 0,
      target: false
    }
  end

  def resolve(game, pending) do
    game
    |> Coupex.Game.resolve_income(pending.actor_id, 3)
    |> Log.log_action_resolution(pending, %{gained: 3})
  end
end
