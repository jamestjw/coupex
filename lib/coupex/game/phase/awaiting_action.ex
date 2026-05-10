defmodule Coupex.Game.Phase.AwaitingAction do
  @moduledoc false
  use Coupex.Game.Phase

  alias Coupex.Game.Log
  alias Coupex.Game.Phase
  alias Coupex.Game.Validation

  def interaction(game, viewer_id) do
    %{kind: :action, your_turn: viewer_id == game.active_player_id}
  end

  def awaiting(game) do
    %{
      kind: :action,
      actor_ids: [game.active_player_id],
      required?: true,
      actions: [:take_action],
      subject: nil
    }
  end

  def handle_action(game, actor_id, action_id, target_id) do
    with {:ok, spec} <- Coupex.Game.fetch_action(action_id),
         :ok <-
           Validation.validate(game, actor_id, [
             :active,
             :turn,
             {:phase, :awaiting_action},
             {:action_allowed, spec},
             {:target, spec, target_id}
           ]) do
      pending = %{
        actor_id: actor_id,
        actor_name: Coupex.Game.player_name(game, actor_id),
        action: spec.id,
        action_label: spec.label,
        claim_role: spec.claim,
        target_id: target_id,
        target_name: Coupex.Game.target_name(game, target_id),
        block_roles: Phase.block_roles(spec.id),
        block_candidates: Phase.block_candidates(game, actor_id, spec.id, target_id),
        cost: spec.cost
      }

      game = Coupex.Game.pay_cost(game, actor_id, spec.cost)
      game = Log.push_log(game, Log.event(:action, Log.describe_action(pending)))

      cond do
        spec.id == "income" ->
          {:ok, Coupex.Game.advance_or_finish(Coupex.Game.resolve_income(game, actor_id, 1))}

        spec.id == "coup" ->
          {:ok,
           Coupex.Game.begin_reveal_phase(
             game,
             target_id,
             "Choose an influence to lose to the coup.",
             %{type: :advance_turn}
           )}

        spec.claim != nil ->
          {:ok,
           Coupex.Game.put_phase(game, %{
             kind: :awaiting_action_responses,
             pending: pending,
             eligible_ids: Coupex.Game.alive_other_player_ids(game, actor_id),
             passed_ids: MapSet.new()
           })}

        pending.block_roles == [] ->
          {:ok, Coupex.Game.after_resolution(Coupex.Game.resolve_action(game, pending))}

        true ->
          {:ok,
           Coupex.Game.put_phase(game, %{
             kind: :awaiting_block,
             pending: pending,
             eligible_ids: pending.block_candidates,
             passed_ids: MapSet.new()
           })}
      end
    end
  end
end
