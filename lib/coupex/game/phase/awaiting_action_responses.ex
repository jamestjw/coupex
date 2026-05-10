defmodule Coupex.Game.Phase.AwaitingActionResponses do
  @moduledoc false
  use Coupex.Game.Phase

  alias Coupex.Game.Validation

  def interaction(game, viewer_id) do
    phase = game.phase
    pending = phase.pending
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
      kind: :respond_action,
      pending: Coupex.Game.public_pending(pending),
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
      kind: :action_response,
      actor_ids: Coupex.Game.remaining_eligible_ids(phase),
      required?: false,
      actions: [:pass, :challenge],
      subject: phase.pending
    }
  end

  def handle_pass(game, player_id) do
    phase = game.phase
    eligible_ids = phase.eligible_ids
    pending = phase.pending

    with :ok <- Validation.validate(game, player_id, [{:member, eligible_ids}]) do
      game = update_in(game.phase.passed_ids, &MapSet.put(&1, player_id))

      if Enum.all?(eligible_ids, &MapSet.member?(game.phase.passed_ids, &1)) do
        Coupex.Game.after_action_responses(game, pending)
      else
        {:ok, game}
      end
    end
  end

  def handle_challenge(game, challenger_id) do
    phase = game.phase
    eligible_ids = phase.eligible_ids
    pending = phase.pending

    with :ok <- Validation.validate(game, challenger_id, [{:member, eligible_ids}]) do
      Coupex.Game.resolve_challenge(game, challenger_id, pending.actor_id, pending.claim_role, %{
        success: %{type: :continue_after_failed_action_challenge, pending: pending},
        failure: %{type: :cancel_after_successful_action_challenge}
      })
    end
  end
end
