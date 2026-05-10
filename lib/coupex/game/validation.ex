defmodule Coupex.Game.Validation do
  @moduledoc false

  alias Coupex.Game.Player

  @type check ::
          :active
          | :turn
          | {:phase, atom()}
          | {:action_allowed, Coupex.Game.Action.t()}
          | {:target, Coupex.Game.Action.t(), String.t() | nil}
          | {:member, [String.t()]}
          | {:block_role, String.t(), atom() | String.t()}
          | {:reveal_index, integer()}
          | {:exchange_indexes, [atom()], [integer()], integer()}

  @spec validate(Coupex.Game.t(), String.t(), [check()]) :: :ok | {:error, String.t()}
  def validate(game, actor_id, checks) do
    Enum.reduce_while(checks, :ok, fn check, :ok ->
      case run_check(game, actor_id, check) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp run_check(game, _actor_id, :active), do: ensure_active(game)
  defp run_check(game, actor_id, :turn), do: ensure_turn(game, actor_id)
  defp run_check(game, _actor_id, {:phase, kind}), do: ensure_phase(game, kind)

  defp run_check(game, actor_id, {:action_allowed, spec}),
    do: ensure_action_allowed(game, actor_id, spec)

  defp run_check(game, actor_id, {:target, spec, target_id}),
    do: ensure_target(game, actor_id, spec, target_id)

  defp run_check(_game, actor_id, {:member, list}), do: ensure_member(list, actor_id)

  defp run_check(_game, _actor_id, {:block_role, action, role}),
    do: ensure_block_role(action, role)

  defp run_check(game, actor_id, {:reveal_index, index}),
    do: ensure_reveal_index(game, actor_id, index)

  defp run_check(_game, _actor_id, {:exchange_indexes, options, indexes, keep_count}),
    do: ensure_exchange_indexes(options, indexes, keep_count)

  @spec ensure_active(Coupex.Game.t()) :: :ok | {:error, String.t()}
  def ensure_active(%{status: :active}), do: :ok
  def ensure_active(_game), do: {:error, "The game is over."}

  @spec ensure_turn(Coupex.Game.t(), String.t()) :: :ok | {:error, String.t()}
  def ensure_turn(game, player_id) do
    if game.active_player_id == player_id, do: :ok, else: {:error, "It is not your turn."}
  end

  @spec ensure_phase(Coupex.Game.t(), atom()) :: :ok | {:error, String.t()}
  def ensure_phase(game, expected_kind) do
    if game.phase.kind == expected_kind,
      do: :ok,
      else: {:error, "That action is not available right now."}
  end

  @spec ensure_action_allowed(Coupex.Game.t(), String.t(), Coupex.Game.Action.t()) ::
          :ok | {:error, String.t()}
  def ensure_action_allowed(game, player_id, spec) do
    player = Player.fetch!(game.players, player_id)

    cond do
      player.coins >= 10 and spec.id != "coup" ->
        {:error, "You must coup when you have 10 or more coins."}

      player.coins < spec.cost ->
        {:error, "You do not have enough coins."}

      true ->
        :ok
    end
  end

  @spec ensure_target(Coupex.Game.t(), String.t(), Coupex.Game.Action.t(), String.t() | nil) ::
          :ok | {:error, String.t()}
  def ensure_target(_game, _actor_id, %{target: false}, nil), do: :ok

  def ensure_target(game, actor_id, %{target: true}, target_id) do
    cond do
      is_nil(target_id) ->
        {:error, "Choose a target."}

      actor_id == target_id ->
        {:error, "You cannot target yourself."}

      is_nil(Enum.find(game.players, &(&1.id == target_id and not Player.eliminated?(&1)))) ->
        {:error, "Choose a living target."}

      true ->
        :ok
    end
  end

  def ensure_target(_game, _actor_id, _spec, _target_id),
    do: {:error, "This action does not take a target."}

  @spec ensure_member([String.t()], String.t()) :: :ok | {:error, String.t()}
  def ensure_member(list, player_id) do
    if player_id in list, do: :ok, else: {:error, "You cannot respond here."}
  end

  @spec ensure_block_role(String.t(), atom() | String.t()) :: :ok | {:error, String.t()}
  def ensure_block_role(action, role) when is_binary(role) do
    try do
      ensure_block_role(action, String.to_existing_atom(role))
    rescue
      ArgumentError -> {:error, "That role cannot block this action."}
    end
  end

  def ensure_block_role(action, role) do
    if role in block_roles(action),
      do: :ok,
      else: {:error, "That role cannot block this action."}
  end

  @spec ensure_reveal_index(Coupex.Game.t(), String.t(), integer()) :: :ok | {:error, String.t()}
  def ensure_reveal_index(game, player_id, index) do
    player = Player.fetch!(game.players, player_id)
    influence = Enum.at(player.influences, index)

    cond do
      is_nil(influence) -> {:error, "Choose one of your influences."}
      influence.revealed -> {:error, "That influence is already revealed."}
      true -> :ok
    end
  end

  @spec ensure_exchange_indexes([atom()], [integer()], integer()) :: :ok | {:error, String.t()}
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
end
