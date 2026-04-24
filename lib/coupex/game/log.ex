defmodule Coupex.Game.Log do
  @moduledoc false

  def push_log(game, entry) do
    %{game | log: [Map.put_new(entry, :turn, game.turn_number) | game.log]}
  end

  def event(kind, attrs), do: Map.put(attrs, :kind, kind)

  def role_label(role) do
    role
    |> Atom.to_string()
    |> String.capitalize()
  end

  def describe_action(pending) do
    %{
      actor: pending.actor_name,
      detail: pending.action_label,
      target: pending.target_name
    }
    |> maybe_put(:role, pending.claim_role && role_label(pending.claim_role))
    |> maybe_put(:spent, if(pending.cost > 0, do: pending.cost, else: nil))
    |> maybe_put(:gained, if(pending.action == "income", do: 1, else: nil))
  end

  def log_action_resolution(game, pending, attrs) do
    resolution =
      %{
        actor: pending.actor_name,
        role: pending.claim_role && role_label(pending.claim_role),
        verb: "unopposed",
        detail: "#{pending.action_label} stands"
      }
      |> Map.merge(attrs)

    push_log(game, event(:action, resolution))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
