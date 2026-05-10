defmodule Coupex.Bot do
  @moduledoc false

  alias Coupex.Game.Player
  require Logger

  @role_values %{
    "Duke" => 30,
    "Captain" => 24,
    "Assassin" => 22,
    "Ambassador" => 18,
    "Contessa" => 16
  }

  def choose_move(view, game, player_id) do
    case choose_native_move(view, game, player_id) do
      {:ok, move} ->
        move

      {:error, reason} ->
        Logger.warning(
          "native bot failed for player #{player_id} during #{inspect(game.phase.kind)}: #{reason}"
        )

        choose_elixir_move(view, game, player_id)
    end
  end

  defp choose_elixir_move(view, game, player_id) do
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

  defp choose_native_move(view, game, player_id) do
    payload = native_payload(view, game, player_id)

    with {:ok, encoded_payload} <- Jason.encode(payload),
         {:ok, encoded_move} <- Coupex.Bot.Native.choose_move(encoded_payload),
         {:ok, decoded_move} <- Jason.decode(encoded_move),
         {:ok, move} <- decode_native_move(decoded_move, game) do
      {:ok, move}
    else
      {:error, reason} -> {:error, inspect(reason)}
      :error -> {:error, "native move could not be mapped"}
      other -> {:error, inspect(other)}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp native_payload(_view, game, player_id) do
    ids = Enum.map(game.players, & &1.id)
    viewer = player_index(ids, player_id)
    viewer_player = Player.fetch!(game.players, player_id)

    %{
      strategy: "heuristic",
      profile: "balanced",
      seed: native_seed(game, player_id),
      viewer: viewer,
      deck_size: length(game.deck),
      own_hidden_cards:
        viewer_player.influences |> Enum.reject(& &1.revealed) |> Enum.map(&role_id(&1.role)),
      players:
        Enum.map(game.players, fn player ->
          %{
            coins: player.coins,
            hidden_influence: Player.alive_influence_count(player),
            revealed:
              player.influences
              |> Enum.filter(& &1.revealed)
              |> Enum.map(&role_id(&1.role)),
            alive: not Player.eliminated?(player)
          }
        end),
      phase: native_phase(game, ids, player_id, viewer)
    }
  end

  defp native_phase(%{phase: %{kind: :awaiting_action}} = game, ids, _player_id, _viewer) do
    %{kind: "action", actor: player_index(ids, game.active_player_id)}
  end

  defp native_phase(
         %{phase: %{kind: :awaiting_action_responses, pending: pending}} = game,
         ids,
         player_id,
         _viewer
       ) do
    responders = alive_other_player_ids(game, pending.actor_id)

    %{
      kind: "challenge",
      actor: player_index(ids, pending.actor_id),
      action: pending.action,
      target: maybe_player_index(ids, pending.target_id),
      responder_index: responder_index(responders, player_id)
    }
  end

  defp native_phase(
         %{phase: %{kind: :awaiting_block, pending: pending}} = game,
         ids,
         player_id,
         _viewer
       ) do
    responders = block_responder_ids(game, pending)

    %{
      kind: "block",
      actor: player_index(ids, pending.actor_id),
      action: pending.action,
      target: maybe_player_index(ids, pending.target_id),
      responder_index: responder_index(responders, player_id)
    }
  end

  defp native_phase(
         %{phase: %{kind: :awaiting_block_challenge, pending: pending, block: block}} = game,
         ids,
         player_id,
         _viewer
       ) do
    responders = alive_other_player_ids(game, block.player_id)

    %{
      kind: "block_challenge",
      actor: player_index(ids, pending.actor_id),
      action: pending.action,
      target: maybe_player_index(ids, pending.target_id),
      blocker: player_index(ids, block.player_id),
      block_card: role_id(block.role),
      responder_index: responder_index(responders, player_id)
    }
  end

  defp native_phase(
         %{phase: %{kind: :awaiting_reveal, player_id: reveal_id}} = game,
         ids,
         _player_id,
         _viewer
       ) do
    %{
      kind: "reveal",
      player: player_index(ids, reveal_id),
      next_actor: player_index(ids, game.active_player_id)
    }
  end

  defp native_phase(
         %{phase: %{kind: :awaiting_exchange, player_id: exchange_id, options: options}} = game,
         ids,
         _player_id,
         _viewer
       ) do
    player = Player.fetch!(game.players, exchange_id)

    %{
      kind: "exchange",
      player: player_index(ids, exchange_id),
      drawn: options |> remove_roles(hidden_roles(player)) |> Enum.map(&role_id/1)
    }
  end

  defp decode_native_move(%{"kind" => "take_action", "action" => action} = move, game) do
    target_id = move |> Map.get("target") |> target_id(game)
    {:ok, {:take_action, action, target_id}}
  end

  defp decode_native_move(%{"kind" => "pass"}, _game), do: {:ok, {:pass}}
  defp decode_native_move(%{"kind" => "challenge"}, _game), do: {:ok, {:challenge}}

  defp decode_native_move(%{"kind" => "block", "role" => role}, _game) do
    case role_atom(role) do
      nil -> :error
      role -> {:ok, {:block, role}}
    end
  end

  defp decode_native_move(%{"kind" => "reveal", "index" => index}, _game)
       when is_integer(index) do
    {:ok, {:reveal, index}}
  end

  defp decode_native_move(%{"kind" => "exchange", "roles" => roles}, game) when is_list(roles) do
    case exchange_indexes(game.phase.options, roles) do
      {:ok, indexes} -> {:ok, {:exchange, indexes}}
      :error -> :error
    end
  end

  defp decode_native_move(_move, _game), do: :error

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

  defp native_seed(game, player_id) do
    :erlang.phash2(
      {game.round_number, game.turn_number, player_id, length(game.log)},
      4_294_967_295
    )
  end

  defp player_index(ids, player_id), do: Enum.find_index(ids, &(&1 == player_id))
  defp maybe_player_index(_ids, nil), do: nil
  defp maybe_player_index(ids, player_id), do: player_index(ids, player_id)

  defp target_id(nil, _game), do: nil

  defp target_id(index, game) when is_integer(index),
    do: game.players |> Enum.at(index) |> Map.fetch!(:id)

  defp responder_index(responders, player_id) do
    Enum.find_index(responders, &(&1 == player_id)) || 0
  end

  defp alive_other_player_ids(game, player_id) do
    game.players
    |> Enum.reject(&(&1.id == player_id or Player.eliminated?(&1)))
    |> Enum.map(& &1.id)
  end

  defp block_responder_ids(game, %{action: "foreign_aid", actor_id: actor_id}) do
    alive_other_player_ids(game, actor_id)
  end

  defp block_responder_ids(game, %{action: action, target_id: target_id})
       when action in ["assassinate", "steal"] do
    target = Player.fetch!(game.players, target_id)

    if Player.eliminated?(target), do: [], else: [target_id]
  end

  defp block_responder_ids(_game, _pending), do: []

  defp exchange_indexes(options, roles) do
    options = Enum.map(options, &role_id/1)

    {indexes, _used} =
      Enum.reduce_while(roles, {[], MapSet.new()}, fn role, {indexes, used} ->
        case first_unused_index(options, used, role) do
          nil -> {:halt, {:error, used}}
          index -> {:cont, {[index | indexes], MapSet.put(used, index)}}
        end
      end)

    case indexes do
      :error -> :error
      indexes when length(indexes) == length(roles) -> {:ok, Enum.sort(indexes)}
      _ -> :error
    end
  end

  defp first_unused_index(options, used, role) do
    options
    |> Enum.with_index()
    |> Enum.find_value(fn {option, index} ->
      if option == role and not MapSet.member?(used, index), do: index
    end)
  end

  defp remove_roles(options, roles) do
    {remaining, _removed} =
      Enum.reduce(roles, {options, []}, fn role, {remaining, removed} ->
        case remove_one(remaining, role) do
          {:ok, remaining} -> {remaining, [role | removed]}
          :error -> {remaining, removed}
        end
      end)

    remaining
  end

  defp remove_one(roles, role) do
    case Enum.find_index(roles, &(&1 == role)) do
      nil -> :error
      index -> {:ok, List.delete_at(roles, index)}
    end
  end

  defp role_atom("duke"), do: :duke
  defp role_atom("assassin"), do: :assassin
  defp role_atom("captain"), do: :captain
  defp role_atom("ambassador"), do: :ambassador
  defp role_atom("contessa"), do: :contessa
  defp role_atom(_role), do: nil

  defp hidden_roles(%Player{} = player) do
    player.influences
    |> Enum.reject(& &1.revealed)
    |> Enum.map(& &1.role)
  end

  defp hidden_roles(view) do
    Enum.map(view.you.influences, & &1.role)
  end

  defp role_label(role) when is_atom(role), do: role |> Atom.to_string() |> String.capitalize()
  defp role_label(role), do: role

  defp role_id(role) when is_atom(role), do: Atom.to_string(role)

  defp role_id(role) when is_binary(role),
    do: role |> String.downcase() |> String.replace(" ", "_")

  defp card_value(role), do: Map.get(@role_values, role_label(role), 0)
end
