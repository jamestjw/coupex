defmodule Coupex.Game.Phase.AwaitingBlock do
  @moduledoc false
  use Coupex.Game.Phase

  alias Coupex.Game.Log
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

    block_roles = if can_respond, do: pending.block_roles, else: []

    %{
      kind: :block,
      pending: Coupex.Game.public_pending(pending),
      block_roles: Enum.map(block_roles, &Log.role_label/1),
      block_role_ids: Enum.map(block_roles, &Atom.to_string/1),
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
      kind: :block,
      actor_ids: Coupex.Game.remaining_eligible_ids(phase),
      required?: false,
      actions: [:pass, :block],
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
        {:ok, Coupex.Game.resolve_and_advance(game, pending)}
      else
        {:ok, game}
      end
    end
  end

  def handle_block(game, blocker_id, role) do
    phase = game.phase
    pending = phase.pending
    eligible_ids = phase.eligible_ids

    with :ok <-
           Validation.validate(game, blocker_id, [
             {:member, eligible_ids},
             {:block_role, pending.action, role}
           ]) do
      block = %{player_id: blocker_id, role: role}

      game =
        Log.push_log(
          game,
          Log.event(:block, %{
            actor: Coupex.Game.player_name(game, blocker_id),
            role: Log.role_label(role),
            detail: "blocked #{pending.action_label}"
          })
        )

      {:ok,
       Coupex.Game.put_phase(game, %{
         kind: :awaiting_block_challenge,
         pending: pending,
         block: block,
         eligible_ids: Coupex.Game.alive_other_player_ids(game, blocker_id),
         passed_ids: MapSet.new()
       })}
    end
  end
end
