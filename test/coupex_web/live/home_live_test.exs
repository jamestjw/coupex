defmodule CoupexWeb.HomeLiveTest do
  use CoupexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the landing page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#entry-form")
    assert has_element?(view, ".landing-title")
    assert has_element?(view, "button[name='intent'][value='create']")
  end

  test "creating a room navigates to the room page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    render_submit(view, "submit_entry", %{
      "entry" => %{"name" => "Isolde", "room_code" => ""},
      "intent" => "create"
    })

    {path, _flash} = assert_redirect(view)
    assert path =~ ~r|/rooms/[A-Z0-9]{6}\?name=Isolde|
  end
end
