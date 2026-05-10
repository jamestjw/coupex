defmodule Coupex.Game.Phase.AwaitingBlockChallenge do
  @moduledoc false
  use Coupex.Game.Phase

  alias Coupex.Game.Log
  alias Coupex.Game.Validation

  def interaction(game, viewer_id) do
    phase = game.phase
    pending = phase.pending
    block = phase.block
    eligible_ids = phase.eligible_ids
    passed_ids = phase.passed_ids

    can_respond = viewer_id in eligible_ids and not MapSet.member?(passed_ids, viewer_id)

    pending_responder_ids =
      Enum.reject(eligible_ids, fn player_id -> MapSet.member?(passed_ids, player_id) end)

    awaiting_others =
      viewer_id in eligible_ids and
        MapSet.member?(passed_ids, viewer_id) and
        Enum.any?(eligible_ids, fn player_id ->
          player_id != viewer_id and not MapSet.member?(passed_ids, player_id)
        end)

    %{
      kind: :respond_block,
      pending: Coupex.Game.public_pending(pending),
      block: %{
        player_id: block.player_id,
        player_name: Coupex.Game.player_name(game, block.player_id),
        role: Log.role_label(block.role)
      },
      can_challenge: can_respond,
      can_pass: can_respond,
      awaiting_others: awaiting_others,
      waiting_on_ids: pending_responder_ids,
      waiting_on_name:
        case pending_responder_ids do
          [single_player_id] -> Coupex.Game.player_name(game, single_player_id)
          _ -> nil
        end
    }
  end

  def awaiting(game) do
    phase = game.phase

    %{
      kind: :block_response,
      actor_ids: Coupex.Game.remaining_eligible_ids(phase),
      required?: false,
      actions: [:pass, :challenge],
      subject: %{pending: phase.pending, block: phase.block}
    }
  end

  def handle_pass(game, player_id) do
    phase = game.phase
    eligible_ids = phase.eligible_ids
    block = phase.block

    with :ok <- Validation.ensure_member(eligible_ids, player_id) do
      game = update_in(game.phase.passed_ids, &MapSet.put(&1, player_id))

      if Enum.all?(eligible_ids, &MapSet.member?(game.phase.passed_ids, &1)) do
        game =
          Log.push_log(
            game,
            Log.event(:block, %{
              actor: Coupex.Game.player_name(game, block.player_id),
              detail: "held the block"
            })
          )

        {:ok, Coupex.Game.advance_or_finish(%{game | phase: %{kind: :awaiting_action}})}
      else
        {:ok, game}
      end
    end
  end

  def handle_challenge(game, challenger_id) do
    phase = game.phase
    eligible_ids = phase.eligible_ids
    pending = phase.pending
    block = phase.block

    with :ok <- Validation.ensure_member(eligible_ids, challenger_id) do
      Coupex.Game.resolve_challenge(game, challenger_id, block.player_id, block.role, %{
        success: %{type: :block_stands},
        failure: %{type: :resume_after_successful_block_challenge, pending: pending}
      })
    end
  end
end
