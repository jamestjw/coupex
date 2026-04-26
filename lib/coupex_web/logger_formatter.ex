defmodule CoupexWeb.LoggerFormatter do
  @moduledoc false

  def format(level, message, timestamp, metadata) do
    event = %{
      timestamp: format_timestamp(timestamp),
      level: to_string(level),
      message: format_message(message),
      metadata: format_metadata(metadata)
    }

    [Jason.encode!(event), ?\n]
  end

  defp format_timestamp({date, time}) do
    [Logger.Formatter.format_date(date), ?T, Logger.Formatter.format_time(time)]
    |> IO.iodata_to_binary()
  end

  defp format_message(message) when is_binary(message), do: message
  defp format_message(message) when is_list(message), do: IO.iodata_to_binary(message)

  defp format_message(message) do
    inspect(message, limit: :infinity, printable_limit: :infinity)
  end

  defp format_metadata(metadata) do
    Enum.into(metadata, %{}, fn {key, value} ->
      {to_string(key), normalize_value(value)}
    end)
  end

  defp normalize_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp normalize_value(value) when is_atom(value), do: to_string(value)
  defp normalize_value(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)
end
