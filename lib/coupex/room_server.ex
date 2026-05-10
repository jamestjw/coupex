defmodule Coupex.RoomServer do
  @moduledoc false

  use GenServer

  require Logger

  alias Coupex.Game
  alias Coupex.Game.Log
  alias Coupex.Lobby

  @type player_id :: String.t()
  @type role :: :duke | :assassin | :captain | :ambassador | :contessa

  @type lobby_player :: %{
          required(:id) => player_id(),
          required(:name) => String.t(),
          required(:ready) => boolean(),
          required(:host) => boolean(),
          required(:bot) => boolean()
        }
  @type rematch :: %{
          optional(:winner_id) => player_id() | nil,
          optional(:host_ready) => boolean(),
          optional(:challenger_ready) => boolean()
        }

  @type view :: %{
          required(:code) => String.t(),
          required(:viewer_id) => player_id(),
          required(:host_id) => player_id() | nil,
          required(:player_count) => non_neg_integer(),
          required(:can_start) => boolean(),
          required(:lobby_players) => [lobby_player()],
          required(:game) => Game.t() | nil,
          required(:rematch) => rematch()
        }

  @type room :: %{
          required(:lobby) => Lobby.t(),
          required(:game) => Game.t() | nil,
          optional(:bot_turn_ref) => reference() | nil,
          optional(:bot_turn_timer_ref) => reference() | nil
        }

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

  @spec create_room() :: {:ok, String.t()} | {:error, String.t()}
  def create_room do
    code = unique_code()

    with {:ok, _room} <- DynamicSupervisor.start_child(Coupex.RoomSupervisor, {__MODULE__, code}) do
      {:ok, code}
    end
  end

  def via(code), do: {:via, Registry, {Coupex.RoomRegistry, normalize_code(code)}}

  @spec create_room(player_id(), String.t(), pid()) :: {:ok, String.t()} | {:error, String.t()}
  def create_room(player_id, name, pid) do
    with {:ok, code} <- create_room(),
         {:ok, _snapshot} <- join_room(code, player_id, name, pid) do
      {:ok, code}
    end
  end

  @spec join_room(String.t(), player_id(), String.t(), pid()) ::
          {:ok, view()} | {:error, String.t()}
  def join_room(code, player_id, name, pid) do
    GenServer.call(via(code), {:join_room, player_id, name, pid})
  catch
    :exit, _ -> {:error, "That room does not exist."}
  end

  @spec snapshot(String.t(), player_id()) :: {:ok, view()} | {:error, String.t()}
  def snapshot(code, viewer_id) do
    GenServer.call(via(code), {:snapshot, viewer_id})
  catch
    :exit, _ -> {:error, "That room does not exist."}
  end

  @spec toggle_ready(String.t(), player_id()) :: {:ok, view()} | {:error, String.t()}
  def toggle_ready(code, player_id), do: GenServer.call(via(code), {:toggle_ready, player_id})

  @spec start_game(String.t(), player_id()) :: {:ok, view()} | {:error, String.t()}
  def start_game(code, player_id), do: GenServer.call(via(code), {:start_game, player_id})

  @spec add_bot(String.t(), player_id()) :: {:ok, view()} | {:error, String.t()}
  def add_bot(code, player_id), do: GenServer.call(via(code), {:add_bot, player_id})

  @spec remove_bot(String.t(), player_id(), player_id()) :: {:ok, view()} | {:error, String.t()}
  def remove_bot(code, player_id, bot_id),
    do: GenServer.call(via(code), {:remove_bot, player_id, bot_id})

  @spec toggle_rematch_ready(String.t(), player_id()) :: {:ok, view()} | {:error, String.t()}
  def toggle_rematch_ready(code, player_id),
    do: GenServer.call(via(code), {:toggle_rematch_ready, player_id})

  @spec restart_game(String.t(), player_id()) :: {:ok, view()} | {:error, String.t()}
  def restart_game(code, player_id), do: GenServer.call(via(code), {:restart_game, player_id})

  @spec take_action(String.t(), player_id(), String.t(), String.t() | nil) ::
          {:ok, view()} | {:error, String.t()}
  def take_action(code, player_id, action_id, target_id),
    do: GenServer.call(via(code), {:take_action, player_id, action_id, target_id})

  @spec pass(String.t(), player_id()) :: {:ok, view()} | {:error, String.t()}
  def pass(code, player_id), do: GenServer.call(via(code), {:pass, player_id})

  @spec challenge(String.t(), player_id()) :: {:ok, view()} | {:error, String.t()}
  def challenge(code, player_id), do: GenServer.call(via(code), {:challenge, player_id})

  @spec block(String.t(), player_id(), role()) :: {:ok, view()} | {:error, String.t()}
  def block(code, player_id, role_id), do: GenServer.call(via(code), {:block, player_id, role_id})

  @spec reveal(String.t(), player_id(), non_neg_integer()) :: {:ok, view()} | {:error, String.t()}
  def reveal(code, player_id, index), do: GenServer.call(via(code), {:reveal, player_id, index})

  @spec exchange(String.t(), player_id(), [non_neg_integer()]) ::
          {:ok, view()} | {:error, String.t()}
  def exchange(code, player_id, indexes),
    do: GenServer.call(via(code), {:exchange, player_id, indexes})

  @spec subscribe(String.t()) :: :ok | {:error, String.t()}
  def subscribe(code), do: Phoenix.PubSub.subscribe(Coupex.PubSub, topic(code))

  @min_players 2
  @max_players 6
  @bot_turn_delay_ms 450

  @impl true
  def init(code) do
    {:ok,
     %{
       lobby: Lobby.new(normalize_code(code)),
       game: nil,
       bot_turn_ref: nil,
       bot_turn_timer_ref: nil
     }}
  end

  @impl true
  @spec handle_call({:join_room, player_id(), String.t(), pid()}, GenServer.from(), room()) ::
          {:reply, {:ok, view()} | {:error, String.t()}, room()}
  def handle_call({:join_room, player_id, name, pid}, _from, state) do
    player_already_joined_room = Map.has_key?(state.lobby.players, player_id)

    cond do
      map_size(state.lobby.players) >= @max_players and not player_already_joined_room ->
        {:reply, {:error, "That room is already full."}, state}

      state.game && not player_already_joined_room ->
        {:reply, {:error, "This game is already in progress."}, state}

      true ->
        ref = Process.monitor(pid)
        existing = Map.get(state.lobby.players, player_id)

        if existing && is_reference(existing.monitor_ref),
          do: Process.demonitor(existing.monitor_ref, [:flush])

        next_state = %{state | lobby: Lobby.join(state.lobby, player_id, name, pid, ref)}
        broadcast(next_state)
        {:reply, {:ok, view(next_state, player_id)}, next_state}
    end
  end

  def handle_call({:snapshot, viewer_id}, _from, state),
    do: {:reply, {:ok, view(state, viewer_id)}, state}

  def handle_call({:toggle_ready, player_id}, _from, state) do
    with :ok <- ensure_waiting(state),
         {:ok, lobby} <- Lobby.toggle_ready(state.lobby, player_id) do
      next_state = %{state | lobby: lobby}
      broadcast(next_state)
      {:reply, {:ok, view(next_state, player_id)}, next_state}
    else
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:start_game, player_id}, _from, state) do
    with :ok <- Lobby.ensure_host(state.lobby, player_id),
         :ok <- ensure_waiting(state),
         :ok <- Lobby.ensure_player_count(state.lobby),
         :ok <- Lobby.ensure_all_ready(state.lobby),
         {:ok, game} <- Game.new(Lobby.starting_players(state.lobby)) do
      next_state =
        %{state | game: game, lobby: Lobby.reset_ready(state.lobby)} |> schedule_bot_turn()

      broadcast(next_state)
      {:reply, {:ok, view(next_state, player_id)}, next_state}
    else
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:add_bot, player_id}, _from, state) do
    with :ok <- Lobby.ensure_host(state.lobby, player_id),
         :ok <- ensure_waiting(state),
         :ok <- Lobby.ensure_room_has_space(state.lobby) do
      next_state = %{state | lobby: Lobby.add_bot(state.lobby)} |> schedule_bot_turn()
      broadcast(next_state)
      {:reply, {:ok, view(next_state, player_id)}, next_state}
    else
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:remove_bot, player_id, bot_id}, _from, state) do
    with :ok <- Lobby.ensure_host(state.lobby, player_id),
         :ok <- ensure_waiting(state),
         :ok <- Lobby.ensure_bot_player(state.lobby, bot_id) do
      next_state = %{state | lobby: Lobby.remove_player(state.lobby, bot_id)}
      broadcast(next_state)
      {:reply, {:ok, view(next_state, player_id)}, next_state}
    else
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:toggle_rematch_ready, player_id}, _from, state) do
    with :ok <- ensure_finished(state),
         {:ok, player} <- Map.fetch(state.lobby.players, player_id),
         :ok <-
           if(Lobby.connected_player?(player),
             do: :ok,
             else: {:error, "Reconnect before joining a rematch."}
           ),
         :ok <-
           if(Lobby.rematch_host_id(state.lobby) == player_id,
             do: {:error, "Host readiness is implied for rematches."},
             else: :ok
           ) do
      {:ok, lobby} = Lobby.toggle_ready(state.lobby, player_id)
      next_state = %{state | lobby: lobby}
      broadcast(next_state)
      {:reply, {:ok, view(next_state, player_id)}, next_state}
    else
      :error -> {:reply, {:error, "Join the room before acting."}, state}
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:restart_game, player_id}, _from, state) do
    rematch_host_id = Lobby.rematch_host_id(state.lobby)

    with :ok <- ensure_finished(state),
         :ok <-
           if(rematch_host_id == player_id,
             do: :ok,
             else: {:error, "Only the rematch host can restart the game."}
           ),
         connected_ids <- Lobby.connected_player_ids(state.lobby),
         :ok <-
           if(length(connected_ids) in @min_players..@max_players,
             do: :ok,
             else:
               {:error, "At least #{@min_players} connected players are required for a rematch."}
           ),
         :ok <- ensure_connected_rematch_ready(state, rematch_host_id, connected_ids),
         play_order = Lobby.rematch_play_order(state.lobby, rematch_host_id, connected_ids),
         next_lobby =
           state.lobby
           |> Lobby.prune_to_players(play_order)
           |> Map.put(:host_id, rematch_host_id),
         {:ok, game} <- Game.new(Lobby.starting_players(next_lobby)) do
      next_state =
        %{state | lobby: Lobby.reset_ready(next_lobby), game: game}
        |> schedule_bot_turn()

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
  def handle_info({:run_bot_turn, ref}, %{bot_turn_ref: ref} = state) do
    state = %{state | bot_turn_ref: nil, bot_turn_timer_ref: nil}

    next_state =
      case bot_actor_id(state) do
        nil ->
          state

        bot_id ->
          case play_bot_turn(state, bot_id) do
            {:ok, next_state} -> schedule_bot_turn(next_state)
            {:error, message} -> log_bot_failure(state, bot_id, message)
          end
      end

    broadcast(next_state)
    {:noreply, next_state}
  end

  def handle_info({:run_bot_turn, _ref}, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    next_state =
      case Enum.find(state.lobby.players, fn {_player_id, player} -> player.monitor_ref == ref end) do
        {player_id, _player} -> handle_player_disconnect(state, player_id)
        nil -> state
      end

    if next_state.lobby.order == [] do
      {:stop, :normal, next_state}
    else
      broadcast(next_state)
      {:noreply, next_state}
    end
  end

  defp reply_with_game(state, player_id, fun) do
    with {:ok, _player} <- Map.fetch(state.lobby.players, player_id),
         %{} = game <- state.game,
         {:ok, updated_game} <- fun.(game) do
      next_state = %{state | game: updated_game} |> schedule_bot_turn()
      broadcast(next_state)
      {:reply, {:ok, view(next_state, player_id)}, next_state}
    else
      nil -> {:reply, {:error, "The game has not started yet."}, state}
      :error -> {:reply, {:error, "Join the room before acting."}, state}
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  defp view(state, viewer_id) do
    players = Lobby.lobby_players_view(state.lobby)

    %{
      code: state.lobby.code,
      viewer_id: viewer_id,
      host_id: state.lobby.host_id,
      player_count: length(players),
      can_start: length(players) in @min_players..@max_players,
      lobby_players: players,
      game: state.game && Game.view(state.game, viewer_id),
      rematch: Lobby.rematch_view(state.lobby, if(state.game, do: state.game.status, else: nil))
    }
  end

  defp handle_player_disconnect(%{game: nil} = state, player_id) do
    %{state | lobby: Lobby.remove_player(state.lobby, player_id)}
  end

  defp handle_player_disconnect(state, player_id) do
    case Map.fetch(state.lobby.players, player_id) do
      {:ok, player} ->
        state = %{state | lobby: Lobby.disconnect_player(state.lobby, player_id)}

        update_in(state.game, fn game ->
          Log.push_log(game, Log.event(:break, %{text: "#{player.name} disconnected"}))
        end)

      :error ->
        state
    end
  end

  defp ensure_connected_rematch_ready(state, rematch_host_id, connected_ids) do
    pending_ids =
      Enum.reject(connected_ids, fn player_id ->
        player_id == rematch_host_id or Map.fetch!(state.lobby.players, player_id).ready
      end)

    if pending_ids == [],
      do: :ok,
      else: {:error, "All connected players must be ready before restarting."}
  end

  defp ensure_waiting(state) do
    if is_nil(state.game), do: :ok, else: {:error, "The game is already underway."}
  end

  defp ensure_finished(%{game: %{status: :finished}}), do: :ok
  defp ensure_finished(%{game: nil}), do: {:error, "The game has not started yet."}
  defp ensure_finished(_state), do: {:error, "The game is still in progress."}

  defp bot_actor_id(%{game: game} = state) do
    game
    |> Game.actors_waiting()
    |> Enum.find(&bot_player?(state, &1))
  end

  defp bot_actor_id(_game), do: nil

  defp bot_player?(state, player_id) do
    case Map.get(state.lobby.players, player_id) do
      %{bot: true} -> true
      _ -> false
    end
  end

  defp play_bot_turn(%{game: game} = state, bot_id) do
    view = Game.view(game, bot_id)

    case Coupex.Bot.choose_move(view, game, bot_id) do
      {:take_action, action_id, target_id} ->
        update_game(state, Game.declare_action(game, bot_id, action_id, target_id))

      {:pass} ->
        update_game(state, Game.pass(game, bot_id))

      {:challenge} ->
        update_game(state, Game.challenge(game, bot_id))

      {:block, role} ->
        update_game(state, Game.block(game, bot_id, role))

      {:reveal, index} ->
        update_game(state, Game.reveal_influence(game, bot_id, index))

      {:exchange, indexes} ->
        update_game(state, Game.choose_exchange(game, bot_id, indexes))

      nil ->
        {:error, "Bot had no legal move."}
    end
  end

  defp update_game(state, {:ok, game}), do: {:ok, %{state | game: game}}
  defp update_game(_state, {:error, message}), do: {:error, message}

  defp log_bot_failure(%{game: nil} = state, bot_id, message) do
    Logger.warning("bot #{bot_id} failed without an active game: #{message}")
    state
  end

  defp log_bot_failure(%{game: game} = state, bot_id, message) do
    bot_name = state.lobby.players |> Map.fetch!(bot_id) |> Map.fetch!(:name)

    Logger.warning(
      "bot #{bot_id} failed in room #{state.lobby.code} during #{inspect(game.phase.kind)}: #{message}"
    )

    entry =
      Log.event(:bot_error, %{
        actor: bot_name,
        detail: "bot move failed: #{message}"
      })

    %{state | game: Log.push_log(game, entry)}
  end

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
    Phoenix.PubSub.broadcast(
      Coupex.PubSub,
      topic(state.lobby.code),
      {:room_updated, state.lobby.code}
    )
  end

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

  defp schedule_bot_turn(%{game: nil} = state), do: cancel_bot_turn(state)
  defp schedule_bot_turn(%{game: %{status: :finished}} = state), do: cancel_bot_turn(state)

  defp schedule_bot_turn(state) do
    if bot_actor_id(state) do
      if state.bot_turn_ref do
        state
      else
        ref = make_ref()
        timer_ref = Process.send_after(self(), {:run_bot_turn, ref}, @bot_turn_delay_ms)
        %{state | bot_turn_ref: ref, bot_turn_timer_ref: timer_ref}
      end
    else
      cancel_bot_turn(state)
    end
  end

  defp cancel_bot_turn(%{bot_turn_timer_ref: timer_ref} = state) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    %{state | bot_turn_ref: nil, bot_turn_timer_ref: nil}
  end

  defp cancel_bot_turn(state), do: %{state | bot_turn_ref: nil, bot_turn_timer_ref: nil}
end
