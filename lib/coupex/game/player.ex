defmodule Coupex.Game.Player do
  @moduledoc false

  @type role :: :duke | :assassin | :captain | :ambassador | :contessa
  @type card :: %{required(:role) => role(), required(:revealed) => boolean()}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          coins: non_neg_integer(),
          influences: [card()]
        }

  defstruct [:id, :name, coins: 2, influences: []]

  def alive_influence_count(player), do: Enum.count(player.influences, &(not &1.revealed))
  def eliminated?(player), do: alive_influence_count(player) == 0

  def fetch!(players, player_id) do
    Enum.find(players, &(&1.id == player_id)) || raise "missing player #{player_id}"
  end
end
