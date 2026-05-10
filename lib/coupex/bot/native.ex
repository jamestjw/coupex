defmodule Coupex.Bot.Native do
  @moduledoc false

  use Rustler, otp_app: :coupex, crate: "coupex_bot"

  def choose_move(_payload), do: :erlang.nif_error(:nif_not_loaded)
end
