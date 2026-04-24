defmodule CoupexWeb.RoomLiveTest do
  use CoupexWeb.ConnCase, async: true

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, init_test_session: 2]
  import Phoenix.LiveViewTest

  alias Coupex.RoomServer

  test "host can start once all players are ready", %{conn: conn} do
    player_one_id = "player-one"
    player_two_id = "player-two"

    {:ok, code} = RoomServer.create_room(player_one_id, "player 1", self())
    assert {:ok, _snapshot} = RoomServer.join_room(code, player_two_id, "player 2", self())

    {:ok, host_view, _html} =
      conn
      |> init_test_session(visitor_id: player_one_id)
      |> live(~p"/rooms/#{code}?name=player 1")

    {:ok, guest_view, _html} =
      build_conn()
      |> init_test_session(visitor_id: player_two_id)
      |> live(~p"/rooms/#{code}?name=player 2")

    host_view |> element("button[phx-click='toggle_ready']") |> render_click()
    guest_view |> element("button[phx-click='toggle_ready']") |> render_click()

    host_view |> element("button[phx-click='start_game']") |> render_click()

    assert has_element?(host_view, ".table-stage")
    assert has_element?(host_view, ".chronicle-panel")
    assert has_element?(guest_view, ".table-stage")
  end
end
