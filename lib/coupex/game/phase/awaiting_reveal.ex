defmodule Coupex.Game.Phase.AwaitingReveal do
  @moduledoc false
  use Coupex.Game.Phase

  alias Coupex.Game.Validation

  def interaction(game, viewer_id) do
    phase = game.phase
    player_id = phase.player_id
    reason = phase.reason

    %{
      kind: :reveal,
      reason: reason,
      your_turn: viewer_id == player_id,
      player_name: Coupex.Game.player_name(game, player_id)
    }
  end

  def awaiting(game) do
    phase = game.phase

    %{
      kind: :reveal,
      actor_ids: [phase.player_id],
      required?: true,
      actions: [:reveal],
      subject: %{reason: phase.reason}
    }
  end

  def handle_reveal(game, player_id, index) do
    phase = game.phase
    continuation = phase.continuation

    if phase.player_id == player_id do
      with :ok <- Validation.validate(game, player_id, [{:reveal_index, index}]) do
        game = Coupex.Game.reveal_player_influence(game, player_id, index)
        game = Coupex.Game.check_winner(game)

        if game.status == :finished do
          {:ok, Coupex.Game.put_phase(game, %{kind: :game_over})}
        else
          Coupex.Game.continue_after_reveal(game, continuation)
        end
      end
    else
      {:error, "Another player must choose an influence first."}
    end
  end
end
