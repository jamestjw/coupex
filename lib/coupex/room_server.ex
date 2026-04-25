defmodule Coupex.RoomServer do
  @moduledoc false

  use GenServer

  alias Coupex.Game

  @topic_prefix "room:"
  @block_roles %{
    "duke" => :duke,
    "assassin" => :assassin,
    "captain" => :captain,
    "ambassador" => :ambassador,
    "contessa" => :contessa
  }

  def child_spec(code) do
    normalized_code = normalize_code(code)

    %{
      id: {__MODULE__, normalized_code},
      start: {__MODULE__, :start_link, [normalized_code]},
      restart: :transient
    }
  end

  def start_link(code) do
    GenServer.start_link(__MODULE__, code, name: via(code))
  end

  def create_room do
    code = unique_code()

    with {:ok, _room} <- DynamicSupervisor.start_child(Coupex.RoomSupervisor, {__MODULE__, code}) do
      {:ok, code}
    end
  end

  def via(code), do: {:via, Registry, {Coupex.RoomRegistry, normalize_code(code)}}

  def create_room(player_id, name, pid) do
    with {:ok, code} <- create_room(),
         {:ok, _snapshot} <- join_room(code, player_id, name, pid) do
      {:ok, code}
    end
  end

  def join_room(code, player_id, name, pid) do
    GenServer.call(via(code), {:join_room, player_id, name, pid})
  catch
    :exit, _ -> {:error, "That room does not exist."}
  end

  def snapshot(code, viewer_id) do
    GenServer.call(via(code), {:snapshot, viewer_id})
  catch
    :exit, _ -> {:error, "That room does not exist."}
  end

  def toggle_ready(code, player_id), do: GenServer.call(via(code), {:toggle_ready, player_id})
  def start_game(code, player_id), do: GenServer.call(via(code), {:start_game, player_id})

  def toggle_rematch_ready(code, player_id),
    do: GenServer.call(via(code), {:toggle_rematch_ready, player_id})

  def restart_game(code, player_id), do: GenServer.call(via(code), {:restart_game, player_id})

  def take_action(code, player_id, action_id, target_id),
    do: GenServer.call(via(code), {:take_action, player_id, action_id, target_id})

  def pass(code, player_id), do: GenServer.call(via(code), {:pass, player_id})
  def challenge(code, player_id), do: GenServer.call(via(code), {:challenge, player_id})
  def block(code, player_id, role_id), do: GenServer.call(via(code), {:block, player_id, role_id})
  def reveal(code, player_id, index), do: GenServer.call(via(code), {:reveal, player_id, index})

  def exchange(code, player_id, indexes),
    do: GenServer.call(via(code), {:exchange, player_id, indexes})

  def subscribe(code), do: Phoenix.PubSub.subscribe(Coupex.PubSub, topic(code))

  @impl true
  def init(code) do
    {:ok,
     %{
       code: normalize_code(code),
       host_id: nil,
       players: %{},
       order: [],
       game: nil
     }}
  end

  @impl true
  def handle_call({:join_room, player_id, name, pid}, _from, state) do
    normalized_name = normalize_name(name)

    cond do
      map_size(state.players) >= 6 and not Map.has_key?(state.players, player_id) ->
        {:reply, {:error, "That room is already full."}, state}

      state.game && not Map.has_key?(state.players, player_id) ->
        {:reply, {:error, "This game is already in progress."}, state}

      true ->
        {players, order, host_id} = upsert_player(state, player_id, normalized_name, pid)
        next_state = %{state | players: players, order: order, host_id: host_id}
        broadcast(next_state)
        {:reply, {:ok, view(next_state, player_id)}, next_state}
    end
  end

  def handle_call({:snapshot, viewer_id}, _from, state),
    do: {:reply, {:ok, view(state, viewer_id)}, state}

  def handle_call({:toggle_ready, player_id}, _from, state) do
    with {:ok, player} <- fetch_room_player(state, player_id),
         :ok <- ensure_waiting(state) do
      updated = %{player | ready: not player.ready}
      next_state = put_in(state.players[player_id], updated)
      broadcast(next_state)
      {:reply, {:ok, view(next_state, player_id)}, next_state}
    else
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:start_game, player_id}, _from, state) do
    with :ok <- ensure_host(state, player_id),
         :ok <- ensure_waiting(state),
         :ok <- ensure_player_count(state),
         :ok <- ensure_all_ready(state),
         {:ok, game} <- Game.new(starting_players(state)) do
      next_state = %{state | game: game, players: reset_ready(state.players)}
      broadcast(next_state)
      {:reply, {:ok, view(next_state, player_id)}, next_state}
    else
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:toggle_rematch_ready, player_id}, _from, state) do
    with {:ok, player} <- fetch_room_player(state, player_id),
         :ok <- ensure_finished(state),
         :ok <- ensure_connected_player(player),
         :ok <- ensure_not_rematch_host(state, player_id) do
      updated = %{player | ready: not player.ready}
      next_state = put_in(state.players[player_id], updated)
      broadcast(next_state)
      {:reply, {:ok, view(next_state, player_id)}, next_state}
    else
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:restart_game, player_id}, _from, state) do
    rematch_host_id = rematch_host_id(state)

    with :ok <- ensure_finished(state),
         :ok <- ensure_rematch_host(rematch_host_id, player_id),
         {:ok, connected_ids} <- ensure_connected_player_count(state),
         :ok <- ensure_connected_rematch_ready(state, rematch_host_id, connected_ids),
         play_order = Enum.shuffle(connected_ids),
         {:ok, game} <- Game.new(starting_players(state, play_order)) do
      next_state =
        state
        |> prune_to_players(play_order)
        |> Map.put(:host_id, rematch_host_id)
        |> Map.put(:game, game)
        |> Map.update!(:players, &reset_ready/1)

      broadcast(next_state)
      {:reply, {:ok, view(next_state, player_id)}, next_state}
    else
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:take_action, player_id, action_id, target_id}, _from, state) do
    reply_with_game(state, player_id, fn game ->
      Game.declare_action(game, player_id, action_id, target_id)
    end)
  end

  def handle_call({:pass, player_id}, _from, state) do
    reply_with_game(state, player_id, fn game -> Game.pass(game, player_id) end)
  end

  def handle_call({:challenge, player_id}, _from, state) do
    reply_with_game(state, player_id, fn game -> Game.challenge(game, player_id) end)
  end

  def handle_call({:block, player_id, role_id}, _from, state) do
    with {:ok, role} <- parse_block_role(role_id) do
      reply_with_game(state, player_id, fn game ->
        Game.block(game, player_id, role)
      end)
    else
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:reveal, player_id, index}, _from, state) do
    reply_with_game(state, player_id, fn game -> Game.reveal_influence(game, player_id, index) end)
  end

  def handle_call({:exchange, player_id, indexes}, _from, state) do
    reply_with_game(state, player_id, fn game ->
      Game.choose_exchange(game, player_id, indexes)
    end)
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    next_state =
      case Enum.find(state.players, fn {_player_id, player} -> player.monitor_ref == ref end) do
        {player_id, _player} -> handle_player_disconnect(state, player_id)
        nil -> state
      end

    if next_state.order == [] do
      {:stop, :normal, next_state}
    else
      broadcast(next_state)
      {:noreply, next_state}
    end
  end

  defp reply_with_game(state, player_id, fun) do
    with {:ok, _player} <- fetch_room_player(state, player_id),
         %{} = game <- state.game,
         {:ok, updated_game} <- fun.(game) do
      next_state = %{state | game: updated_game}
      broadcast(next_state)
      {:reply, {:ok, view(next_state, player_id)}, next_state}
    else
      nil -> {:reply, {:error, "The game has not started yet."}, state}
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  defp view(state, viewer_id) do
    players =
      Enum.map(state.order, fn player_id ->
        player = Map.fetch!(state.players, player_id)

        %{
          id: player.id,
          name: player.name,
          ready: player.ready,
          host: player.id == state.host_id
        }
      end)

    %{
      code: state.code,
      viewer_id: viewer_id,
      host_id: state.host_id,
      player_count: length(players),
      can_start: length(players) in 2..6,
      lobby_players: players,
      game: state.game && Game.view(state.game, viewer_id),
      rematch: rematch_view(state)
    }
  end

  defp remove_player(state, player_id) do
    players = Map.delete(state.players, player_id)
    order = List.delete(state.order, player_id)
    host_id = if state.host_id == player_id, do: List.first(order), else: state.host_id

    %{state | players: players, order: order, host_id: host_id}
  end

  defp handle_player_disconnect(%{game: nil} = state, player_id),
    do: remove_player(state, player_id)

  defp handle_player_disconnect(state, player_id) do
    case Map.fetch(state.players, player_id) do
      {:ok, player} ->
        put_in(state.players[player_id], %{player | monitor_ref: nil, pid: nil})

      :error ->
        state
    end
  end

  defp upsert_player(state, player_id, name, pid) do
    ref = Process.monitor(pid)
    existing = Map.get(state.players, player_id)

    if existing && is_reference(existing.monitor_ref),
      do: Process.demonitor(existing.monitor_ref, [:flush])

    player = %{
      id: player_id,
      name: choose_name(name, existing),
      ready: if(existing, do: existing.ready, else: false),
      monitor_ref: ref,
      pid: pid
    }

    players = Map.put(state.players, player_id, player)
    order = if player_id in state.order, do: state.order, else: state.order ++ [player_id]
    host_id = state.host_id || player_id

    {players, order, host_id}
  end

  defp starting_players(state, player_ids \\ nil) do
    ids = player_ids || state.order

    Enum.map(ids, fn player_id ->
      player = Map.fetch!(state.players, player_id)
      %{id: player.id, name: player.name}
    end)
  end

  defp reset_ready(players) do
    Map.new(players, fn {id, player} -> {id, %{player | ready: false}} end)
  end

  defp fetch_room_player(state, player_id) do
    case Map.fetch(state.players, player_id) do
      {:ok, player} -> {:ok, player}
      :error -> {:error, "Join the room before acting."}
    end
  end

  defp ensure_host(state, player_id) do
    if state.host_id == player_id, do: :ok, else: {:error, "Only the host can start the game."}
  end

  defp ensure_player_count(state) do
    if length(state.order) in 2..6, do: :ok, else: {:error, "Coup requires 2 to 6 players."}
  end

  defp ensure_all_ready(state) do
    if Enum.all?(state.players, fn {_id, player} -> player.ready end) do
      :ok
    else
      {:error, "Every seated player must be ready before the game can begin."}
    end
  end

  defp ensure_waiting(state) do
    if is_nil(state.game), do: :ok, else: {:error, "The game is already underway."}
  end

  defp ensure_finished(%{game: %{status: :finished}}), do: :ok
  defp ensure_finished(%{game: nil}), do: {:error, "The game has not started yet."}
  defp ensure_finished(_state), do: {:error, "The game is still in progress."}

  defp ensure_connected_player(%{pid: pid}) when is_pid(pid), do: :ok
  defp ensure_connected_player(_player), do: {:error, "Reconnect before joining a rematch."}

  defp ensure_not_rematch_host(state, player_id) do
    if rematch_host_id(state) == player_id,
      do: {:error, "Host readiness is implied for rematches."},
      else: :ok
  end

  defp ensure_rematch_host(nil, _player_id),
    do: {:error, "Not enough connected players to restart."}

  defp ensure_rematch_host(rematch_host_id, player_id) do
    if rematch_host_id == player_id,
      do: :ok,
      else: {:error, "Only the rematch host can restart the game."}
  end

  defp ensure_connected_player_count(state) do
    connected_ids = connected_player_ids(state)

    if length(connected_ids) in 2..6,
      do: {:ok, connected_ids},
      else: {:error, "At least 2 connected players are required for a rematch."}
  end

  defp ensure_connected_rematch_ready(state, rematch_host_id, connected_ids) do
    pending_ids =
      Enum.reject(connected_ids, fn player_id ->
        player_id == rematch_host_id or Map.fetch!(state.players, player_id).ready
      end)

    if pending_ids == [],
      do: :ok,
      else: {:error, "All connected players must be ready before restarting."}
  end

  defp connected_player_ids(state) do
    Enum.filter(state.order, fn player_id ->
      state.players
      |> Map.fetch!(player_id)
      |> connected_player?()
    end)
  end

  defp connected_player?(%{pid: pid}) when is_pid(pid), do: true
  defp connected_player?(_player), do: false

  defp rematch_host_id(state) do
    connected_ids = connected_player_ids(state)

    cond do
      connected_ids == [] -> nil
      state.host_id in connected_ids -> state.host_id
      true -> List.first(connected_ids)
    end
  end

  defp prune_to_players(state, player_ids) do
    players = Map.take(state.players, player_ids)
    host_id = if state.host_id in player_ids, do: state.host_id, else: List.first(player_ids)

    %{state | players: players, order: player_ids, host_id: host_id}
  end

  defp rematch_view(%{game: %{status: :finished}} = state) do
    connected_ids = connected_player_ids(state)
    host_id = rematch_host_id(state)

    players =
      Enum.map(connected_ids, fn player_id ->
        player = Map.fetch!(state.players, player_id)

        %{
          id: player.id,
          name: player.name,
          ready: player_id == host_id or player.ready,
          host: player_id == host_id
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
      min_players_met: connected_count >= 2,
      max_players_met: connected_count <= 6,
      can_restart: pending_names == [] and connected_count in 2..6,
      pending_names: pending_names
    }
  end

  defp rematch_view(_state), do: nil

  defp parse_block_role(role_id) when is_binary(role_id) do
    role_id
    |> String.trim()
    |> String.downcase()
    |> then(&Map.fetch(@block_roles, &1))
    |> case do
      {:ok, role} -> {:ok, role}
      :error -> {:error, "That role cannot block this action."}
    end
  end

  defp parse_block_role(_role_id), do: {:error, "That role cannot block this action."}

  defp topic(code), do: @topic_prefix <> normalize_code(code)

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Coupex.PubSub, topic(state.code), {:room_updated, state.code})
  end

  # Race condition: We generate a code, check it's free, then register it.
  # In the nanosecond gap between lookup and start_link, another process
  # could grab the same code. This results in {:error, {:already_started, pid}}.
  # Not worth fixing: 62^6 (~56B) codes, window is nanoseconds.
  defp unique_code do
    code =
      5
      |> :crypto.strong_rand_bytes()
      |> Base.encode32(case: :upper, padding: false)
      |> binary_part(0, 6)

    case Registry.lookup(Coupex.RoomRegistry, code) do
      [] -> code
      _ -> unique_code()
    end
  end

  defp normalize_code(code) do
    code
    |> to_string()
    |> String.trim()
    |> String.upcase()
  end

  defp normalize_name(name) do
    trimmed = name |> to_string() |> String.trim()
    if trimmed == "", do: nil, else: String.slice(trimmed, 0, 24)
  end

  defp choose_name(nil, nil), do: "Player"
  defp choose_name(name, nil), do: name
  defp choose_name(_name, existing), do: existing.name
end
