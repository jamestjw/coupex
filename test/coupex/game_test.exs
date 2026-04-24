defmodule Coupex.GameTest do
  use ExUnit.Case, async: true

  alias Coupex.Game

  test "players with 10 or more coins must coup" do
    game = base_game(%{coins: 10}, %{})

    assert {:error, "You must coup when you have 10 or more coins."} =
             Game.declare_action(game, "p1", "income")
  end

  test "assassination waits for target reveal after responses finish" do
    game =
      base_game(%{coins: 4}, %{})
      |> Map.put(:phase, %{
        kind: :awaiting_block,
        pending: %{
          actor_id: "p1",
          actor_name: "Isolde",
          action: "assassinate",
          action_label: "Assassinate",
          claim_role: :assassin,
          target_id: "p2",
          target_name: "Magnus",
          block_roles: [:contessa],
          block_candidates: ["p2"],
          cost: 3
        },
        eligible_ids: ["p2"],
        passed_ids: MapSet.new()
      })

    assert {:ok, updated} = Game.pass(game, "p2")
    assert updated.phase.kind == :awaiting_reveal
    assert updated.phase.player_id == "p2"
  end

  test "exchange waits for the actor to choose cards" do
    game =
      base_game(%{}, %{})
      |> Map.put(:phase, %{
        kind: :awaiting_action_responses,
        pending: %{
          actor_id: "p1",
          actor_name: "Isolde",
          action: "exchange",
          action_label: "Exchange",
          claim_role: :ambassador,
          target_id: nil,
          target_name: nil,
          block_roles: [],
          block_candidates: [],
          cost: 0
        },
        eligible_ids: ["p2"],
        passed_ids: MapSet.new()
      })

    assert {:ok, updated} = Game.pass(game, "p2")
    assert updated.phase.kind == :awaiting_exchange
    assert updated.phase.player_id == "p1"
  end

  defp base_game(player_one_overrides, player_two_overrides) do
    %{
      status: :active,
      active_player_id: "p1",
      turn_number: 1,
      round_number: 1,
      treasury: 46,
      deck: [:duke, :captain, :ambassador, :contessa, :assassin],
      winner_id: nil,
      phase: %{kind: :awaiting_action},
      log: [],
      players: [
        Map.merge(
          %{
            id: "p1",
            name: "Isolde",
            coins: 2,
            influences: [%{role: :duke, revealed: false}, %{role: :captain, revealed: false}]
          },
          player_one_overrides
        ),
        Map.merge(
          %{
            id: "p2",
            name: "Magnus",
            coins: 2,
            influences: [%{role: :assassin, revealed: false}, %{role: :contessa, revealed: false}]
          },
          player_two_overrides
        )
      ]
    }
  end
end
