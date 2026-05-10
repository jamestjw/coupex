defmodule Coupex.Game.Action.Coup do
  @moduledoc false
  use Coupex.Game.Action

  def spec do
    %{
      id: "coup",
      label: "Coup",
      detail: "Pay 7 to force influence loss",
      claim: nil,
      cost: 7,
      target: true
    }
  end

  def resolve(game, _pending) do
    # Coup is handled specially in declare_action currently because it's immediate
    # but for completeness we can keep it here.
    game
  end
end
