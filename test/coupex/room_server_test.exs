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
end
