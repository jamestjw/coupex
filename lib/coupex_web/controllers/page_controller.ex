defmodule CoupexWeb.PageController do
  use CoupexWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
