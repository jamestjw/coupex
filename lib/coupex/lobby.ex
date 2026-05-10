defmodule Coupex.Lobby do
  @moduledoc false

  @min_players 2
  @max_players 6

  @type player_id :: String.t()

  @type player :: %{
          id: player_id(),
          name: String.t(),
          ready: boolean(),
          bot: boolean(),
          monitor_ref: reference() | nil,
          pid: pid() | nil
        }

  @type t :: %__MODULE__{
          code: String.t(),
          host_id: player_id() | nil,
          players: %{optional(player_id()) => player()},
          order: [player_id()]
        }

  defstruct [:code, :host_id, players: %{}, order: []]

  def new(code) do
    %__MODULE__{code: code}
  end

  def join(lobby, player_id, name, pid, monitor_ref) do
    normalized_name = normalize_name(name)
    existing = Map.get(lobby.players, player_id)

    player = %{
      id: player_id,
      name: choose_name(normalized_name, existing),
      ready: if(existing, do: existing.ready, else: false),
      bot: false,
      monitor_ref: monitor_ref,
      pid: pid
    }

    players = Map.put(lobby.players, player_id, player)
    order = if player_id in lobby.order, do: lobby.order, else: lobby.order ++ [player_id]
    host_id = lobby.host_id || player_id

    %{lobby | players: players, order: order, host_id: host_id}
  end

  def remove_player(lobby, player_id) do
    players = Map.delete(lobby.players, player_id)
    order = List.delete(lobby.order, player_id)
    host_id = if lobby.host_id == player_id, do: List.first(order), else: lobby.host_id

    %{lobby | players: players, order: order, host_id: host_id}
  end

  def disconnect_player(lobby, player_id) do
    case Map.fetch(lobby.players, player_id) do
      {:ok, player} ->
        player = %{player | monitor_ref: nil, pid: nil}
        put_in(lobby.players[player_id], player)

      :error ->
        lobby
    end
  end

  def toggle_ready(lobby, player_id) do
    case Map.fetch(lobby.players, player_id) do
      {:ok, player} ->
        updated = %{player | ready: not player.ready}
        {:ok, put_in(lobby.players[player_id], updated)}

      :error ->
        {:error, "Join the room before acting."}
    end
  end

  def reset_ready(lobby) do
    updated_players =
      Map.new(lobby.players, fn {id, player} -> {id, %{player | ready: player.bot}} end)

    %{lobby | players: updated_players}
  end

  def add_bot(lobby) do
    bot_index = next_bot_index(lobby)
    bot_id = "bot-#{bot_index}"

    player = %{
      id: bot_id,
      name: "Bot #{bot_index}",
      ready: true,
      bot: true,
      monitor_ref: nil,
      pid: nil
    }

    players = Map.put(lobby.players, bot_id, player)
    order = lobby.order ++ [bot_id]

    %{lobby | players: players, order: order}
  end

  def starting_players(lobby) do
    Enum.map(lobby.order, fn player_id ->
      player = Map.fetch!(lobby.players, player_id)
      %{id: player.id, name: player.name}
    end)
  end

  def connected_player_ids(lobby) do
    Enum.filter(lobby.order, fn player_id ->
      lobby.players
      |> Map.fetch!(player_id)
      |> connected_player?()
    end)
  end

  def connected_player?(%{pid: pid}) when is_pid(pid), do: true
  def connected_player?(%{bot: true}), do: true
  def connected_player?(_player), do: false

  def rematch_host_id(lobby) do
    connected_ids = connected_player_ids(lobby)

    cond do
      connected_ids == [] -> nil
      lobby.host_id in connected_ids -> lobby.host_id
      true -> List.first(connected_ids)
    end
  end

  def rematch_play_order(lobby, rematch_host_id, connected_ids) do
    connected_set = MapSet.new(connected_ids)

    ordered_connected_ids =
      Enum.filter(lobby.order, fn player_id -> MapSet.member?(connected_set, player_id) end)

    case ordered_connected_ids do
      [] -> Enum.shuffle(connected_ids)
      ids -> rotate_to(ids, rematch_host_id)
    end
  end

  def prune_to_players(lobby, player_ids) do
    players = Map.take(lobby.players, player_ids)
    host_id = if lobby.host_id in player_ids, do: lobby.host_id, else: List.first(player_ids)

    %{lobby | players: players, order: player_ids, host_id: host_id}
  end

  def ensure_host(lobby, player_id) do
    if lobby.host_id == player_id, do: :ok, else: {:error, "Only the host can start the game."}
  end

  def ensure_player_count(lobby) do
    if length(lobby.order) in @min_players..@max_players,
      do: :ok,
      else: {:error, "Coup requires #{@min_players} to #{@max_players} players."}
  end

  def ensure_all_ready(lobby) do
    if Enum.all?(lobby.players, fn {_id, player} -> player.ready end) do
      :ok
    else
      {:error, "Every seated player must be ready before the game can begin."}
    end
  end

  def ensure_room_has_space(lobby) do
    if map_size(lobby.players) < @max_players,
      do: :ok,
      else: {:error, "That room is already full."}
  end

  def ensure_bot_player(lobby, bot_id) do
    case Map.fetch(lobby.players, bot_id) do
      {:ok, player} ->
        if player.bot, do: :ok, else: {:error, "That seat is not a bot."}

      :error ->
        {:error, "Join the room before acting."}
    end
  end

  def lobby_players_view(lobby) do
    Enum.map(lobby.order, fn player_id ->
      player = Map.fetch!(lobby.players, player_id)

      %{
        id: player.id,
        name: player.name,
        ready: player.ready,
        host: player.id == lobby.host_id,
        bot: player.bot
      }
    end)
  end

  def rematch_view(lobby, game_status) do
    if game_status == :finished do
      connected_ids = connected_player_ids(lobby)
      host_id = rematch_host_id(lobby)

      players =
        Enum.map(connected_ids, fn player_id ->
          player = Map.fetch!(lobby.players, player_id)

          %{
            id: player.id,
            name: player.name,
            ready: player_id == host_id or player.ready,
            host: player_id == host_id,
            bot: player.bot
          }
        end)

      pending_names =
        players
        |> Enum.reject(&(&1.host or &1.ready))
        |> Enum.map(& &1.name)

      connected_count = length(connected_ids)

      %{
        host_id: host_id,
        connected_players: players,
        connected_count: connected_count,
        min_players_met: connected_count >= @min_players,
        max_players_met: connected_count <= @max_players,
        can_restart: pending_names == [] and connected_count in @min_players..@max_players,
        pending_names: pending_names
      }
    else
      nil
    end
  end

  defp normalize_name(name) do
    trimmed = name |> to_string() |> String.trim()
    if trimmed == "", do: nil, else: String.slice(trimmed, 0, 24)
  end

  defp choose_name(nil, nil), do: "Player"
  defp choose_name(name, nil), do: name
  defp choose_name(_name, existing), do: existing.name

  defp next_bot_index(lobby) do
    lobby.players
    |> Map.keys()
    |> Enum.map(fn id ->
      case Regex.run(~r/^bot-(\d+)$/, id) do
        [_, number] -> String.to_integer(number)
        _ -> 0
      end
    end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp rotate_to(ids, player_id) do
    case Enum.split_while(ids, &(&1 != player_id)) do
      {_before, []} -> ids
      {before, after_and_player} -> after_and_player ++ before
    end
  end
end
