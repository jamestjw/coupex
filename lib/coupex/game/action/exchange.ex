defmodule Coupex.Game.Action.Exchange do
  @moduledoc false
  use Coupex.Game.Action

  def spec do
    %{
      id: "exchange",
      label: "Exchange",
      detail: "Claim Ambassador to redraw",
      claim: :ambassador,
      cost: 0,
      target: false
    }
  end

  def resolve(game, pending) do
    Coupex.Game.begin_exchange(game, pending.actor_id)
  end
end
