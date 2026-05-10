defmodule Coupex.Game.Phase.GameOver do
  @moduledoc false
  use Coupex.Game.Phase

  def interaction(_game, _viewer_id) do
    %{kind: :game_over}
  end

  def awaiting(_game) do
    %{kind: :none, actor_ids: [], required?: false, actions: [], subject: nil}
  end
end
