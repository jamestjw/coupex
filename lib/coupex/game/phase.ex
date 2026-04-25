defmodule Coupex.Game.Phase do
  @moduledoc false

  alias Coupex.Game.Validation

  @type phase :: %{
          required(:kind) => atom(),
          optional(:pending) => map(),
          optional(:eligible_ids) => [String.t()],
          optional(:passed_ids) => map(),
          optional(:exchange_cards) => [map()]
        }

  @type t :: phase()

  def block_candidates(game, actor_id, "foreign_aid", _target_id),
    do: alive_other_player_ids(game, actor_id)

  def block_candidates(game, _actor_id, action, target_id)
      when action in ["assassinate", "steal"] do
    if Enum.any?(game.players, &(&1.id == target_id and not eliminated?(&1))) do
      [target_id]
    else
      []
    end
  end

  def block_candidates(_game, _actor_id, _action, _target_id), do: []

  def block_roles(action), do: Validation.block_roles(action)

  defp alive_other_player_ids(game, player_id) do
    game.players
    |> Enum.reject(&(&1.id == player_id or eliminated?(&1)))
    |> Enum.map(& &1.id)
  end

  defp eliminated?(player), do: alive_influence_count(player) == 0
  defp alive_influence_count(player), do: Enum.count(player.influences, &(not &1.revealed))
end
