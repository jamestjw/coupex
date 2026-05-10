defmodule Coupex.Game.Action.Income do
  @moduledoc false
  use Coupex.Game.Action

  def spec do
    %{id: "income", label: "Income", detail: "Take 1 coin", claim: nil, cost: 0, target: false}
  end

  def resolve(game, _pending) do
    # Income is handled specially in declare_action currently because it's immediate
    # but for completeness we can keep it here.
    game
  end
end
