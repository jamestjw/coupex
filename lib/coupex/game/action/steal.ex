defmodule Coupex.Game.Action.Steal do
  @moduledoc false
  use Coupex.Game.Action

  alias Coupex.Game.Log

  def spec do
    %{
      id: "steal",
      label: "Steal",
      detail: "Claim Captain to take 2",
      claim: :captain,
      cost: 0,
      target: true
    }
  end

  def resolve(game, pending) do
    {game, amount} = Coupex.Game.resolve_steal(game, pending.actor_id, pending.target_id)
    Log.log_action_resolution(game, pending, %{gained: amount, lost: amount})
  end
end
