defmodule Coupex.Game.Validation do
  @moduledoc false

  def ensure_active(%{status: :active}), do: :ok
  def ensure_active(_game), do: {:error, "The game is over."}

  def ensure_turn(game, player_id) do
    if game.active_player_id == player_id, do: :ok, else: {:error, "It is not your turn."}
  end

  def ensure_phase(game, expected_kind) do
    if game.phase.kind == expected_kind,
      do: :ok,
      else: {:error, "That action is not available right now."}
  end

  def ensure_action_allowed(game, player_id, spec) do
    player = fetch_player!(game, player_id)

    cond do
      player.coins >= 10 and spec.id != "coup" ->
        {:error, "You must coup when you have 10 or more coins."}

      player.coins < spec.cost ->
        {:error, "You do not have enough coins."}

      true ->
        :ok
    end
  end

  def ensure_target(_game, _actor_id, %{target: false}, nil), do: :ok

  def ensure_target(game, actor_id, %{target: true}, target_id) do
    cond do
      is_nil(target_id) ->
        {:error, "Choose a target."}

      actor_id == target_id ->
        {:error, "You cannot target yourself."}

      is_nil(Enum.find(game.players, &(&1.id == target_id and not eliminated?(&1)))) ->
        {:error, "Choose a living target."}

      true ->
        :ok
    end
  end

  def ensure_target(_game, _actor_id, _spec, _target_id),
    do: {:error, "This action does not take a target."}

  def ensure_member(list, player_id) do
    if player_id in list, do: :ok, else: {:error, "You cannot respond here."}
  end

  def ensure_block_role(action, role) when is_binary(role),
    do: ensure_block_role(action, String.to_existing_atom(role))

  def ensure_block_role(action, role) do
    if role in block_roles(action),
      do: :ok,
      else: {:error, "That role cannot block this action."}
  end

  def ensure_reveal_index(game, player_id, index) do
    player = fetch_player!(game, player_id)
    influence = Enum.at(player.influences, index)

    cond do
      is_nil(influence) -> {:error, "Choose one of your influences."}
      influence.revealed -> {:error, "That influence is already revealed."}
      true -> :ok
    end
  end

  def ensure_exchange_indexes(options, indexes, keep_count) do
    valid = Enum.all?(indexes, &(&1 >= 0 and &1 < length(options)))

    cond do
      length(indexes) != keep_count -> {:error, "Choose exactly #{keep_count} cards to keep."}
      not valid -> {:error, "Choose valid exchange cards."}
      true -> :ok
    end
  end

  def block_roles("foreign_aid"), do: [:duke]
  def block_roles("assassinate"), do: [:contessa]
  def block_roles("steal"), do: [:captain, :ambassador]
  def block_roles(_), do: []

  defp alive_influence_count(player), do: Enum.count(player.influences, &(not &1.revealed))
  defp eliminated?(player), do: alive_influence_count(player) == 0

  defp fetch_player!(game, player_id) do
    Enum.find(game.players, &(&1.id == player_id)) || raise "missing player #{player_id}"
  end
end
