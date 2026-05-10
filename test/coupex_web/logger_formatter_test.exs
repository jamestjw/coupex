defmodule CoupexWeb.LoggerFormatterTest do
  use ExUnit.Case, async: true

  test "formats a single-line json log" do
    line =
      CoupexWeb.LoggerFormatter.format(
        :info,
        "GET /health/ready",
        {{2026, 4, 26}, {7, 38, 40, 41}},
        request_id: "abc123"
      )
      |> IO.iodata_to_binary()
      |> String.trim_trailing()

    assert %{
             "timestamp" => "2026-04-26T07:38:40.041",
             "level" => "info",
             "message" => "GET /health/ready",
             "metadata" => %{"request_id" => "abc123"}
           } = Jason.decode!(line)
  end
end
