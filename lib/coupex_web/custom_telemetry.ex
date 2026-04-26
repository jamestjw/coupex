defmodule CoupexWeb.CustomTelemetry do
  @doc "Silences logging for health check endpoints"

  def request_log_level(%Plug.Conn{path_info: ["health" | _]}), do: false

  # Fallback: Logs everything else as :info
  def request_log_level(_conn), do: :info
end
