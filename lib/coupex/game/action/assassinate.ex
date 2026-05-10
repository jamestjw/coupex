defmodule Coupex.Game.Action.Assassinate do
  @moduledoc false
  use Coupex.Game.Action

  alias Coupex.Game.Player

  def spec do
    %{
      id: "assassinate",
      label: "Assassinate",
      detail: "Claim Assassin and pay 3",
      claim: :assassin,
      cost: 3,
      target: true
    }
  end

  def resolve(game, pending) do
    if Player.eliminated?(Player.fetch!(game.players, pending.target_id)) do
      # Maybe the player challenged the assassination and failed, and hence is
      # already eliminated, there is nothing we need to do here.
      game
    else
      Coupex.Game.begin_reveal_phase(
        game,
        pending.target_id,
        "Choose an influence to lose to the assassination.",
        %{type: :advance_turn}
      )
    end
  end
end
