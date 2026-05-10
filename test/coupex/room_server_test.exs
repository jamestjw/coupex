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

  test "rematch restart advances immediately when a bot acts first" do
    host_id = "host-player"

    {:ok, code} = RoomServer.create_room(host_id, "Host", self())
    assert {:ok, _snapshot} = RoomServer.add_bot(code, host_id)

    assert {:ok, _snapshot} = RoomServer.toggle_ready(code, host_id)
    assert {:ok, _snapshot} = RoomServer.start_game(code, host_id)

    mark_finished!(code)

    room_pid = GenServer.whereis(RoomServer.via(code))

    :sys.replace_state(room_pid, fn state ->
      state = %{state | order: ["bot-1", host_id]}
      state = put_in(state.players[host_id].ready, true)
      %{state | host_id: "bot-1", game: %{state.game | active_player_id: "bot-1"}}
    end)

    assert {:ok, restarted} = RoomServer.restart_game(code, "bot-1")

    assert restarted.game.status == :active

    assert Enum.any?(restarted.game.log, fn entry ->
             entry.kind == :action and entry.actor == "Bot 1"
           end)
  end

  defp mark_finished!(code) do
    room_pid = GenServer.whereis(RoomServer.via(code))

    :sys.replace_state(room_pid, fn state ->
      %{state | game: %{state.game | status: :finished}}
    end)
  end
end
