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

  test "claimed action shows challenge modal for other players", %{conn: conn} do
    host_id = "host-player"
    guest_id = "guest-player"

    {:ok, code} = RoomServer.create_room(host_id, "Host", self())
    assert {:ok, _snapshot} = RoomServer.join_room(code, guest_id, "Guest", self())

    {:ok, host_view, _html} =
      conn
      |> init_test_session(visitor_id: host_id)
      |> live(~p"/rooms/#{code}?name=Host")

    {:ok, guest_view, _html} =
      build_conn()
      |> init_test_session(visitor_id: guest_id)
      |> live(~p"/rooms/#{code}?name=Guest")

    host_view |> element("button[phx-click='toggle_ready']") |> render_click()
    guest_view |> element("button[phx-click='toggle_ready']") |> render_click()
    host_view |> element("button[phx-click='start_game']") |> render_click()

    host_view
    |> element("button[phx-click='take_action'][phx-value-action='tax']")
    |> render_click()

    assert has_element?(guest_view, "#claim-challenge-modal")
    assert has_element?(guest_view, "#claim-challenge-button")
    assert has_element?(guest_view, "#claim-allow-button")
    assert has_element?(guest_view, "#claim-challenge-timer")
    assert has_element?(guest_view, "[data-claim-countdown]")
    refute has_element?(host_view, "#claim-challenge-modal")
  end

  test "two-player allow does not show waiting-for-others notice", %{conn: conn} do
    host_id = "host-player"
    guest_id = "guest-player"

    {:ok, code} = RoomServer.create_room(host_id, "Host", self())
    assert {:ok, _snapshot} = RoomServer.join_room(code, guest_id, "Guest", self())

    {:ok, host_view, _html} =
      conn
      |> init_test_session(visitor_id: host_id)
      |> live(~p"/rooms/#{code}?name=Host")

    {:ok, guest_view, _html} =
      build_conn()
      |> init_test_session(visitor_id: guest_id)
      |> live(~p"/rooms/#{code}?name=Guest")

    host_view |> element("button[phx-click='toggle_ready']") |> render_click()
    guest_view |> element("button[phx-click='toggle_ready']") |> render_click()
    host_view |> element("button[phx-click='start_game']") |> render_click()

    host_view
    |> element("button[phx-click='take_action'][phx-value-action='tax']")
    |> render_click()

    assert has_element?(guest_view, "#claim-challenge-modal")

    guest_view |> element("#claim-allow-button") |> render_click()

    refute has_element?(guest_view, "#claim-response-waiting")
    refute has_element?(guest_view, "#claim-challenge-modal")
  end

  test "allow dismisses claim modal for responder while waiting on others", %{conn: conn} do
    host_id = "host-player"
    guest_one_id = "guest-one"
    guest_two_id = "guest-two"

    {:ok, code} = RoomServer.create_room(host_id, "Host", self())
    assert {:ok, _snapshot} = RoomServer.join_room(code, guest_one_id, "Guest One", self())
    assert {:ok, _snapshot} = RoomServer.join_room(code, guest_two_id, "Guest Two", self())

    {:ok, host_view, _html} =
      conn
      |> init_test_session(visitor_id: host_id)
      |> live(~p"/rooms/#{code}?name=Host")

    {:ok, guest_one_view, _html} =
      build_conn()
      |> init_test_session(visitor_id: guest_one_id)
      |> live(~p"/rooms/#{code}?name=Guest One")

    {:ok, guest_two_view, _html} =
      build_conn()
      |> init_test_session(visitor_id: guest_two_id)
      |> live(~p"/rooms/#{code}?name=Guest Two")

    host_view |> element("button[phx-click='toggle_ready']") |> render_click()
    guest_one_view |> element("button[phx-click='toggle_ready']") |> render_click()
    guest_two_view |> element("button[phx-click='toggle_ready']") |> render_click()
    host_view |> element("button[phx-click='start_game']") |> render_click()

    host_view
    |> element("button[phx-click='take_action'][phx-value-action='tax']")
    |> render_click()

    assert has_element?(guest_one_view, "#claim-challenge-modal")
    assert has_element?(guest_two_view, "#claim-challenge-modal")

    guest_one_view |> element("#claim-allow-button") |> render_click()

    refute has_element?(guest_one_view, "#claim-challenge-modal")
    assert has_element?(guest_one_view, "#claim-response-waiting")
    assert has_element?(guest_two_view, "#claim-challenge-modal")
  end

  test "block claims use the same challenge modal and timer", %{conn: conn} do
    host_id = "host-player"
    guest_id = "guest-player"

    {:ok, code} = RoomServer.create_room(host_id, "Host", self())
    assert {:ok, _snapshot} = RoomServer.join_room(code, guest_id, "Guest", self())

    {:ok, host_view, _html} =
      conn
      |> init_test_session(visitor_id: host_id)
      |> live(~p"/rooms/#{code}?name=Host")

    {:ok, guest_view, _html} =
      build_conn()
      |> init_test_session(visitor_id: guest_id)
      |> live(~p"/rooms/#{code}?name=Guest")

    host_view |> element("button[phx-click='toggle_ready']") |> render_click()
    guest_view |> element("button[phx-click='toggle_ready']") |> render_click()
    host_view |> element("button[phx-click='start_game']") |> render_click()

    host_view
    |> element("button[phx-click='take_action'][phx-value-action='foreign_aid']")
    |> render_click()

    assert has_element?(guest_view, "#action-block-modal")
    assert has_element?(guest_view, "#action-block-button-0")
    assert has_element?(guest_view, "#action-block-pass-button")
    assert has_element?(guest_view, "#action-block-timer")

    guest_view
    |> element("#action-block-button-0")
    |> render_click()

    assert has_element?(host_view, "#block-challenge-modal")
    assert has_element?(host_view, "#block-challenge-button")
    assert has_element?(host_view, "#block-allow-button")
    assert has_element?(host_view, "#block-challenge-timer")
    refute has_element?(guest_view, "#block-challenge-modal")

    host_view |> element("#block-allow-button") |> render_click()

    refute has_element?(host_view, "#block-response-waiting")
    refute has_element?(host_view, "#block-challenge-modal")
  end

  test "two-player block pass does not show waiting-for-others notice", %{conn: conn} do
    host_id = "host-player"
    guest_id = "guest-player"

    {:ok, code} = RoomServer.create_room(host_id, "Host", self())
    assert {:ok, _snapshot} = RoomServer.join_room(code, guest_id, "Guest", self())

    {:ok, host_view, _html} =
      conn
      |> init_test_session(visitor_id: host_id)
      |> live(~p"/rooms/#{code}?name=Host")

    {:ok, guest_view, _html} =
      build_conn()
      |> init_test_session(visitor_id: guest_id)
      |> live(~p"/rooms/#{code}?name=Guest")

    host_view |> element("button[phx-click='toggle_ready']") |> render_click()
    guest_view |> element("button[phx-click='toggle_ready']") |> render_click()
    host_view |> element("button[phx-click='start_game']") |> render_click()

    host_view
    |> element("button[phx-click='take_action'][phx-value-action='foreign_aid']")
    |> render_click()

    assert has_element?(guest_view, "#action-block-modal")

    guest_view |> element("#action-block-pass-button") |> render_click()

    refute has_element?(guest_view, "#action-block-response-waiting")
    refute has_element?(guest_view, "#action-block-modal")
  end
end
