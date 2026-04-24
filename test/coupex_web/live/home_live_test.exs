defmodule CoupexWeb.HomeLiveTest do
  use CoupexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the landing page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#entry-form")
    assert has_element?(view, ".landing-title")
    assert has_element?(view, "button[name='intent'][value='create']")
  end
end
