defmodule Coupex.RoomServerTest do
  use ExUnit.Case, async: true

  alias Coupex.RoomServer

  test "rejoining the same room does not rename an existing player" do
    player_id = "player-one"

    {:ok, code} = RoomServer.create_room(player_id, "Isolde", self())
    assert {:ok, _snapshot} = RoomServer.join_room(code, player_id, "Magnus", self())
    assert {:ok, snapshot} = RoomServer.snapshot(code, player_id)

    assert [%{id: ^player_id, name: "Isolde"}] = snapshot.lobby_players
  end

  test "room process stops when the final player disconnects" do
    player_id = "player-one"
    player_pid = start_supervised!({Task, fn -> Process.sleep(:infinity) end})

    {:ok, code} = RoomServer.create_room(player_id, "Isolde", player_pid)
    room_pid = GenServer.whereis(RoomServer.via(code))
    room_ref = Process.monitor(room_pid)

    Process.exit(player_pid, :shutdown)

    assert_receive {:DOWN, ^room_ref, :process, ^room_pid, reason}
    assert reason in [:normal, :noproc]
    assert {:error, "That room does not exist."} = RoomServer.snapshot(code, player_id)
  end

  test "player can rejoin in-progress game after reconnect" do
    host_id = "host-player"
    guest_id = "guest-player"
    guest_pid = start_supervised!({Task, fn -> Process.sleep(:infinity) end})

    {:ok, code} = RoomServer.create_room(host_id, "Host", self())
    assert {:ok, _snapshot} = RoomServer.join_room(code, guest_id, "Guest", guest_pid)

    assert {:ok, _snapshot} = RoomServer.toggle_ready(code, host_id)
    assert {:ok, _snapshot} = RoomServer.toggle_ready(code, guest_id)
    assert {:ok, _snapshot} = RoomServer.start_game(code, host_id)

    Process.exit(guest_pid, :shutdown)
    _ = :sys.get_state(GenServer.whereis(RoomServer.via(code)))

    assert {:ok, snapshot} = RoomServer.join_room(code, guest_id, "Guest", self())
    assert snapshot.game.status == :active
  end

  test "rematch host passes to next connected player" do
    host_id = "host-player"
    guest_id = "guest-player"
    ally_id = "ally-player"

    host_pid =
      start_supervised!({Task, fn -> Process.sleep(:infinity) end}, id: {:host_task, make_ref()})

    ally_pid =
      start_supervised!({Task, fn -> Process.sleep(:infinity) end}, id: {:ally_task, make_ref()})

    {:ok, code} = RoomServer.create_room(host_id, "Host", host_pid)
    assert {:ok, _snapshot} = RoomServer.join_room(code, guest_id, "Guest", self())
    assert {:ok, _snapshot} = RoomServer.join_room(code, ally_id, "Ally", ally_pid)

    assert {:ok, _snapshot} = RoomServer.toggle_ready(code, host_id)
    assert {:ok, _snapshot} = RoomServer.toggle_ready(code, guest_id)
    assert {:ok, _snapshot} = RoomServer.toggle_ready(code, ally_id)
    assert {:ok, _snapshot} = RoomServer.start_game(code, host_id)

    mark_finished!(code)

    Process.exit(host_pid, :shutdown)
    ref = Process.monitor(host_pid)
    assert_receive {:DOWN, ^ref, :process, _, _}

    assert {:ok, snapshot} = RoomServer.snapshot(code, guest_id)

    assert snapshot.rematch.host_id in [guest_id, ally_id]

    assert {:ok, _snapshot} = RoomServer.toggle_rematch_ready(code, ally_id)
    assert {:ok, restarted} = RoomServer.restart_game(code, guest_id)
    assert restarted.game.status == :active
    assert length(restarted.game.players) == 2
    assert Enum.sort(Enum.map(restarted.game.players, & &1.id)) == Enum.sort([guest_id, ally_id])
  end

  test "rematch restart requires all connected non-host players ready" do
    host_id = "host-player"
    guest_id = "guest-player"

    {:ok, code} = RoomServer.create_room(host_id, "Host", self())
    assert {:ok, _snapshot} = RoomServer.join_room(code, guest_id, "Guest", self())
    assert {:ok, _snapshot} = RoomServer.toggle_ready(code, host_id)
    assert {:ok, _snapshot} = RoomServer.toggle_ready(code, guest_id)
    assert {:ok, _snapshot} = RoomServer.start_game(code, host_id)

    mark_finished!(code)

    assert {:error, "All connected players must be ready before restarting."} =
             RoomServer.restart_game(code, host_id)

    assert {:ok, _snapshot} = RoomServer.toggle_rematch_ready(code, guest_id)
    assert {:ok, restarted} = RoomServer.restart_game(code, host_id)
    assert restarted.game.status == :active
  end

  test "rematch restart schedules a bot when it acts first" do
    host_id = "host-player"

    {:ok, code} = RoomServer.create_room(host_id, "Host", self())
    assert {:ok, _snapshot} = RoomServer.add_bot(code, host_id)

    assert {:ok, _snapshot} = RoomServer.toggle_ready(code, host_id)
    assert {:ok, _snapshot} = RoomServer.start_game(code, host_id)

    mark_finished!(code)

    room_pid = GenServer.whereis(RoomServer.via(code))

    :sys.replace_state(room_pid, fn state ->
      lobby = %{state.lobby | order: ["bot-1", host_id]}
      lobby = put_in(lobby.players[host_id].ready, true)
      lobby = %{lobby | host_id: "bot-1"}
      %{state | lobby: lobby, game: %{state.game | active_player_id: "bot-1"}}
    end)

    assert {:ok, restarted} = RoomServer.restart_game(code, "bot-1")

    assert restarted.game.status == :active
    assert restarted.game.interaction.kind == :action
    assert restarted.game.active_player_id == "bot-1"

    run_scheduled_bot_turns!(code, 1)
    assert {:ok, snapshot} = RoomServer.snapshot(code, host_id)

    assert Enum.any?(snapshot.game.log, fn entry ->
             entry.kind == :action and entry.actor == "Bot 1"
           end)
  end

  test "bot completes exchange after proving ambassador from a failed challenge" do
    host_id = "host-player"

    {:ok, code} = RoomServer.create_room(host_id, "Host", self())
    assert {:ok, _snapshot} = RoomServer.add_bot(code, host_id)

    assert {:ok, _snapshot} = RoomServer.toggle_ready(code, host_id)
    assert {:ok, _snapshot} = RoomServer.start_game(code, host_id)

    room_pid = GenServer.whereis(RoomServer.via(code))

    :sys.replace_state(room_pid, fn state ->
      pending = %{
        actor_id: "bot-1",
        actor_name: "Bot 1",
        action: "exchange",
        action_label: "Exchange",
        claim_role: :ambassador,
        target_id: nil,
        target_name: nil,
        block_roles: [],
        block_candidates: [],
        cost: 0
      }

      players =
        Enum.map(state.game.players, fn
          %{id: ^host_id} = player ->
            %{
              player
              | influences: [
                  %{role: :assassin, revealed: false},
                  %{role: :captain, revealed: false}
                ]
            }

          %{id: "bot-1"} = player ->
            %{
              player
              | influences: [
                  %{role: :ambassador, revealed: false},
                  %{role: :contessa, revealed: false}
                ]
            }
        end)

      game = %{
        state.game
        | active_player_id: "bot-1",
          turn_number: 2,
          deck: [:duke, :captain, :assassin],
          players: players,
          phase: %{
            kind: :awaiting_reveal,
            player_id: host_id,
            reason: "Your challenge failed. Reveal one influence.",
            continuation: %{type: :continue_after_failed_action_challenge, pending: pending}
          }
      }

      %{state | game: game}
    end)

    assert {:ok, snapshot} = RoomServer.reveal(code, host_id, 0)
    assert snapshot.game.interaction.kind == :exchange
    assert snapshot.game.interaction.your_turn == false

    run_scheduled_bot_turns!(code, 1)
    assert {:ok, snapshot} = RoomServer.snapshot(code, host_id)

    assert snapshot.game.interaction.kind == :action
    assert snapshot.game.active_player_id == host_id

    assert Enum.any?(snapshot.game.log, fn entry ->
             entry.kind == :exchange and entry.actor == "Bot 1" and
               entry.detail == "rearranged the court"
           end)
  end

  defp run_scheduled_bot_turns!(code, limit) do
    room_pid = GenServer.whereis(RoomServer.via(code))

    Enum.reduce_while(1..limit, :ok, fn _step, :ok ->
      case :sys.get_state(room_pid).bot_turn_ref do
        nil ->
          {:halt, :ok}

        ref ->
          send(room_pid, {:run_bot_turn, ref})
          _ = :sys.get_state(room_pid)
          {:cont, :ok}
      end
    end)
  end

  defp mark_finished!(code) do
    room_pid = GenServer.whereis(RoomServer.via(code))

    :sys.replace_state(room_pid, fn state ->
      %{state | game: %{state.game | status: :finished}}
    end)
  end
end
