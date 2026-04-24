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
end
