defmodule Coupex.Game.Phase.AwaitingExchange do
  @moduledoc false
  use Coupex.Game.Phase

  alias Coupex.Game.Log
  alias Coupex.Game.Validation

  def interaction(game, viewer_id) do
    phase = game.phase
    player_id = phase.player_id
    options = phase.options
    keep_count = phase.keep_count

    %{
      kind: :exchange,
      your_turn: viewer_id == player_id,
      keep_count: keep_count,
      options: if(viewer_id == player_id, do: Enum.map(options, &Log.role_label/1), else: [])
    }
  end

  def awaiting(game) do
    phase = game.phase

    %{
      kind: :exchange,
      actor_ids: [phase.player_id],
      required?: true,
      actions: [:exchange],
      subject: %{options: phase.options, keep_count: phase.keep_count}
    }
  end

  def handle_exchange(game, player_id, indexes) do
    phase = game.phase
    options = phase.options
    keep_count = phase.keep_count
    deck_rest = phase.deck_rest

    if phase.player_id == player_id do
      indexes = Enum.uniq(indexes)

      with :ok <- Validation.ensure_exchange_indexes(options, indexes, keep_count) do
        kept = Enum.map(indexes, &Enum.at(options, &1))
        returned = Coupex.Game.list_difference(options, kept)

        game =
          Coupex.Game.update_player(game, player_id, fn player ->
            revealed = Enum.filter(player.influences, & &1.revealed)
            hidden = Enum.map(kept, &%{role: &1, revealed: false})
            %{player | influences: revealed ++ hidden}
          end)

        game = %{game | deck: Enum.shuffle(deck_rest ++ returned)}

        game =
          Log.push_log(
            game,
            Log.event(:exchange, %{
              actor: Coupex.Game.player_name(game, player_id),
              detail: "rearranged the court"
            })
          )

        {:ok, Coupex.Game.advance_or_finish(%{game | phase: %{kind: :awaiting_action}})}
      end
    else
      {:error, "Another player is exchanging cards right now."}
    end
  end
end
