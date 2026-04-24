defmodule CoupexWeb.Plugs.EnsurePlayerId do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :visitor_id) do
      nil -> put_session(conn, :visitor_id, random_id())
      _visitor_id -> conn
    end
  end

  defp random_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
