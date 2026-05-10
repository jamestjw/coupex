defmodule Coupex.Bot do
  @moduledoc false

  @role_values %{
    "Duke" => 30,
    "Captain" => 24,
    "Assassin" => 22,
    "Ambassador" => 18,
    "Contessa" => 16
  }

  def choose_move(view, game, player_id) do
    case view.interaction.kind do
      :action -> choose_action(view)
      :respond_action -> choose_response(view, player_id, view.interaction.pending.claim_role)
      :block -> choose_block(view)
      :respond_block -> choose_response(view, player_id, view.interaction.block.role)
      :reveal -> {:reveal, choose_reveal_index(view)}
      :exchange -> {:exchange, choose_exchange_indexes(game, player_id)}
      _ -> nil
    end
  end

  defp choose_action(view) do
    actions = Enum.reject(view.you.available_actions, & &1.disabled)
    hidden_roles = hidden_roles(view)

    cond do
      Enum.any?(actions, &(&1.id == "coup")) ->
        action = Enum.find(actions, &(&1.id == "coup"))
        {:take_action, action.id, choose_target(view, action)}

      Enum.any?(actions, &(&1.id == "tax")) and "Duke" in hidden_roles ->
        {:take_action, "tax", nil}

      Enum.any?(actions, &(&1.id == "steal")) and "Captain" in hidden_roles ->
        action = Enum.find(actions, &(&1.id == "steal"))
        {:take_action, action.id, choose_target(view, action)}

      Enum.any?(actions, &(&1.id == "assassinate")) and "Assassin" in hidden_roles ->
        action = Enum.find(actions, &(&1.id == "assassinate"))
        {:take_action, action.id, choose_target(view, action)}

      Enum.any?(actions, &(&1.id == "exchange")) and "Ambassador" in hidden_roles ->
        {:take_action, "exchange", nil}

      Enum.any?(actions, &(&1.id == "foreign_aid")) ->
        {:take_action, "foreign_aid", nil}

      true ->
        {:take_action, "income", nil}
    end
  end

  defp choose_response(view, _player_id, claim_role) do
    if should_challenge?(view, claim_role), do: {:challenge}, else: {:pass}
  end

  defp choose_block(view) do
    hidden_roles = hidden_roles(view)

    cond do
      "Duke" in hidden_roles and "Duke" in view.interaction.block_roles ->
        {:block, :duke}

      "Contessa" in hidden_roles and "Contessa" in view.interaction.block_roles ->
        {:block, :contessa}

      "Captain" in hidden_roles and "Captain" in view.interaction.block_roles ->
        {:block, :captain}

      "Ambassador" in hidden_roles and "Ambassador" in view.interaction.block_roles ->
        {:block, :ambassador}

      true ->
        {:pass}
    end
  end

  defp choose_target(view, action) do
    action.targets
    |> Enum.map(&{&1.id, player_rank(view, &1.id)})
    |> Enum.max_by(fn {_id, rank} -> rank end, fn -> {nil, -1} end)
    |> elem(0)
  end

  defp player_rank(view, player_id) do
    case Enum.find(view.players, &(&1.id == player_id)) do
      nil -> -1
      player -> player.coins * 10 + player.alive_count
    end
  end

  defp should_challenge?(_view, nil), do: false

  defp should_challenge?(view, claim_role) do
    hidden_roles = hidden_roles(view)
    visible_count = visible_role_count(view, claim_role)

    claim_role not in hidden_roles and visible_count <= 1
  end

  defp visible_role_count(view, claim_role) do
    own_count = Enum.count(hidden_roles(view), &(&1 == claim_role))

    revealed_count =
      view.players
      |> Enum.flat_map(& &1.influences)
      |> Enum.count(fn influence -> influence.revealed and influence.role == claim_role end)

    own_count + revealed_count
  end

  defp choose_reveal_index(view) do
    view.you.influences
    |> Enum.with_index()
    |> Enum.reject(fn {influence, _index} -> influence.revealed end)
    |> Enum.min_by(fn {influence, _index} -> card_value(influence.role) end, fn -> {nil, 0} end)
    |> elem(1)
  end

  defp choose_exchange_indexes(game, _player_id) do
    phase = game.phase

    keep_count = phase.keep_count

    phase.options
    |> Enum.map(&role_label/1)
    |> Enum.with_index()
    |> Enum.sort_by(fn {card, _index} -> -card_value(card) end)
    |> Enum.take(keep_count)
    |> Enum.map(fn {_card, index} -> index end)
    |> Enum.sort()
  end

  defp hidden_roles(view) do
    Enum.map(view.you.influences, & &1.role)
  end

  defp role_label(role) when is_atom(role), do: role |> Atom.to_string() |> String.capitalize()
  defp role_label(role), do: role

  defp card_value(role), do: Map.get(@role_values, role_label(role), 0)
end
