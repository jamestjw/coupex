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
end
