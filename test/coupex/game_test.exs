defmodule Coupex.GameTest do
  use ExUnit.Case, async: true

  alias Coupex.Game

  test "players with 10 or more coins must coup" do
    game = base_game(%{coins: 10}, %{})

    assert {:error, "You must coup when you have 10 or more coins."} =
             Game.declare_action(game, "p1", "income")
  end

  test "income logs immediate coin gain" do
    game = base_game(%{}, %{})

    assert {:ok, updated} = Game.declare_action(game, "p1", "income")

    assert hd(updated.log).kind == :action
    assert hd(updated.log).gained == 1
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

  test "allowing a tax claim advances to next turn" do
    game =
      base_game(%{}, %{})
      |> Map.put(:phase, %{
        kind: :awaiting_action_responses,
        pending: %{
          actor_id: "p1",
          actor_name: "Isolde",
          action: "tax",
          action_label: "Tax",
          claim_role: :duke,
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
    assert updated.phase.kind == :awaiting_action
    assert updated.active_player_id == "p2"
    assert updated.turn_number == 2
    assert Enum.find(updated.players, &(&1.id == "p1")).coins == 5
    assert hd(updated.log).kind == :action
    assert hd(updated.log).verb == "unopposed"
    assert hd(updated.log).gained == 3
  end

  test "all blocks passed resolves foreign aid and advances turn" do
    game =
      base_game(%{}, %{})
      |> Map.put(:phase, %{
        kind: :awaiting_block,
        pending: %{
          actor_id: "p1",
          actor_name: "Isolde",
          action: "foreign_aid",
          action_label: "Foreign Aid",
          claim_role: nil,
          target_id: nil,
          target_name: nil,
          block_roles: [:duke],
          block_candidates: ["p2"],
          cost: 0
        },
        eligible_ids: ["p2"],
        passed_ids: MapSet.new()
      })

    assert {:ok, updated} = Game.pass(game, "p2")
    assert updated.phase.kind == :awaiting_action
    assert updated.active_player_id == "p2"
    assert updated.turn_number == 2
    assert Enum.find(updated.players, &(&1.id == "p1")).coins == 4
    assert hd(updated.log).kind == :action
    assert hd(updated.log).verb == "unopposed"
    assert hd(updated.log).gained == 2
  end

  test "steal resolution logs gain and loss amounts" do
    game = base_game(%{}, %{coins: 1})

    assert {:ok, game} = Game.declare_action(game, "p1", "steal", "p2")
    assert {:ok, game} = Game.pass(game, "p2")
    assert {:ok, updated} = Game.pass(game, "p2")

    assert hd(updated.log).kind == :action
    assert hd(updated.log).verb == "unopposed"
    assert hd(updated.log).gained == 1
    assert hd(updated.log).lost == 1
  end

  test "assassinate logs spent coins on action declaration" do
    game = base_game(%{coins: 3}, %{})

    assert {:ok, updated} = Game.declare_action(game, "p1", "assassinate", "p2")

    assert hd(updated.log).kind == :action
    assert hd(updated.log).spent == 3
  end

  test "advancing to a new round adds a round break log entry" do
    game = base_game(%{}, %{}) |> Map.put(:active_player_id, "p2")

    assert {:ok, updated} = Game.declare_action(game, "p2", "income")
    assert updated.round_number == 2
    assert hd(updated.log).kind == :break
    assert hd(updated.log).text == "Round 2"
  end

  test "reveal interaction includes whose reveal is pending" do
    game =
      base_game(%{}, %{})
      |> Map.put(:phase, %{
        kind: :awaiting_reveal,
        player_id: "p1",
        reason: "Your bluff was caught. Reveal one influence.",
        continuation: %{type: :advance_turn}
      })

    reveal_for_p1 = Game.view(game, "p1").interaction
    reveal_for_p2 = Game.view(game, "p2").interaction

    assert reveal_for_p1.kind == :reveal
    assert reveal_for_p1.your_turn
    assert reveal_for_p1.player_name == "Isolde"

    assert reveal_for_p2.kind == :reveal
    refute reveal_for_p2.your_turn
    assert reveal_for_p2.player_name == "Isolde"
  end

  test "coup auto-reveals when target has one influence left" do
    game =
      base_game(
        %{coins: 7},
        %{influences: [%{role: :assassin, revealed: true}, %{role: :contessa, revealed: false}]}
      )

    assert {:ok, updated} = Game.declare_action(game, "p1", "coup", "p2")
    assert updated.phase.kind == :game_over
    assert updated.status == :finished
    assert updated.winner_id == "p1"
  end

  test "successful challenge auto-reveals when bluffer has one influence left" do
    game =
      base_game(
        %{influences: [%{role: :captain, revealed: true}, %{role: :assassin, revealed: false}]},
        %{}
      )
      |> Map.put(:phase, %{
        kind: :awaiting_action_responses,
        pending: %{
          actor_id: "p1",
          actor_name: "Isolde",
          action: "tax",
          action_label: "Tax",
          claim_role: :duke,
          target_id: nil,
          target_name: nil,
          block_roles: [],
          block_candidates: [],
          cost: 0
        },
        eligible_ids: ["p2"],
        passed_ids: MapSet.new()
      })

    assert {:ok, updated} = Game.challenge(game, "p2")
    assert updated.phase.kind == :game_over
    assert updated.status == :finished
    assert updated.winner_id == "p2"
  end

  test "a successful challenge resolves the claim without reopening it" do
    game =
      base_game(%{}, %{})
      |> Map.put(:players, [
        %{
          id: "p1",
          name: "Isolde",
          coins: 2,
          influences: [%{role: :duke, revealed: false}, %{role: :contessa, revealed: false}]
        },
        %{
          id: "p2",
          name: "Magnus",
          coins: 2,
          influences: [%{role: :captain, revealed: false}, %{role: :assassin, revealed: false}]
        },
        %{
          id: "p3",
          name: "Livia",
          coins: 2,
          influences: [%{role: :ambassador, revealed: false}, %{role: :contessa, revealed: false}]
        }
      ])
      |> Map.put(:phase, %{
        kind: :awaiting_action_responses,
        pending: %{
          actor_id: "p1",
          actor_name: "Isolde",
          action: "tax",
          action_label: "Tax",
          claim_role: :duke,
          target_id: nil,
          target_name: nil,
          block_roles: [],
          block_candidates: [],
          cost: 0
        },
        eligible_ids: ["p2", "p3"],
        passed_ids: MapSet.new()
      })

    assert {:ok, updated} = Game.challenge(game, "p2")
    assert {:ok, updated} = Game.reveal_influence(updated, "p2", 0)

    assert updated.phase.kind == :awaiting_action
    assert updated.active_player_id == "p2"
    assert updated.turn_number == 2
  end

  test "failed challenge logs replacement influence exchange" do
    game =
      base_game(%{}, %{})
      |> Map.put(:phase, %{
        kind: :awaiting_action_responses,
        pending: %{
          actor_id: "p1",
          actor_name: "Isolde",
          action: "tax",
          action_label: "Tax",
          claim_role: :duke,
          target_id: nil,
          target_name: nil,
          block_roles: [],
          block_candidates: [],
          cost: 0
        },
        eligible_ids: ["p2"],
        passed_ids: MapSet.new()
      })

    assert {:ok, updated} = Game.challenge(game, "p2")

    assert hd(updated.log).kind == :exchange

    assert hd(updated.log).detail ==
             "revealed Duke and exchanged it for a new influence."
  end

  test "failed assassinate challenge with eliminated target advances without blocking" do
    game = %{
      status: :active,
      active_player_id: "p1",
      turn_number: 1,
      round_number: 1,
      treasury: 44,
      deck: [:duke, :captain, :ambassador, :contessa, :assassin],
      winner_id: nil,
      phase: %{kind: :awaiting_action},
      log: [],
      players: [
        %{
          id: "p1",
          name: "Isolde",
          coins: 3,
          influences: [%{role: :assassin, revealed: false}, %{role: :duke, revealed: false}]
        },
        %{
          id: "p2",
          name: "Magnus",
          coins: 2,
          influences: [%{role: :captain, revealed: true}, %{role: :contessa, revealed: false}]
        },
        %{
          id: "p3",
          name: "Rhea",
          coins: 2,
          influences: [%{role: :captain, revealed: false}, %{role: :ambassador, revealed: false}]
        }
      ]
    }

    assert {:ok, game} = Game.declare_action(game, "p1", "assassinate", "p2")
    assert {:ok, updated} = Game.challenge(game, "p2")

    assert updated.phase.kind == :awaiting_action
    assert updated.active_player_id == "p3"
    assert updated.turn_number == 2
  end

  test "failed assassinate challenge still lets the living target block with contessa" do
    game =
      base_three_player_game(
        %{
          coins: 3,
          influences: [%{role: :assassin, revealed: false}, %{role: :duke, revealed: false}]
        },
        %{influences: [%{role: :contessa, revealed: false}, %{role: :captain, revealed: false}]},
        %{influences: [%{role: :duke, revealed: false}, %{role: :captain, revealed: false}]}
      )

    assert {:ok, game} = Game.declare_action(game, "p1", "assassinate", "p2")
    assert {:ok, game} = Game.challenge(game, "p3")
    assert game.phase.kind == :awaiting_reveal
    assert game.phase.player_id == "p3"

    assert {:ok, updated} = Game.reveal_influence(game, "p3", 0)

    assert updated.phase.kind == :awaiting_block
    assert updated.phase.eligible_ids == ["p2"]
    assert updated.phase.pending.action == "assassinate"
    assert updated.phase.pending.block_roles == [:contessa]

    interaction = Game.view(updated, "p2").interaction
    assert interaction.kind == :block
    assert interaction.block_roles == ["Contessa"]
    assert interaction.block_role_ids == ["contessa"]
    assert interaction.can_pass
  end

  test "failed challenge against a truthful block makes challenger reveal and block stands" do
    game =
      base_three_player_game(
        %{},
        %{influences: [%{role: :captain, revealed: false}, %{role: :contessa, revealed: false}]},
        %{}
      )

    assert {:ok, game} = Game.declare_action(game, "p1", "steal", "p2")
    assert {:ok, game} = Game.pass(game, "p2")
    assert {:ok, game} = Game.pass(game, "p3")
    assert {:ok, game} = Game.block(game, "p2", :captain)
    assert {:ok, game} = Game.challenge(game, "p3")

    assert game.phase.kind == :awaiting_reveal
    assert game.phase.player_id == "p3"

    assert {:ok, updated} = Game.reveal_influence(game, "p3", 0)

    assert updated.phase.kind == :awaiting_action
    assert updated.active_player_id == "p2"
    assert updated.turn_number == 2

    assert Enum.any?(updated.log, fn entry ->
             entry.kind == :exchange and
               entry.detail == "revealed Captain and exchanged it for a new influence."
           end)
  end

  test "awaiting state exposes active player actions" do
    game = base_game(%{}, %{})

    assert Game.awaiting(game) == %{
             kind: :action,
             actor_ids: ["p1"],
             required?: true,
             actions: [:take_action],
             subject: nil
           }

    assert Game.actors_waiting(game) == ["p1"]
    assert Game.actor_waiting?(game, "p1")
    refute Game.actor_waiting?(game, "p2")
    assert Game.legal_reactions(game, "p1") == [:take_action]
    assert Game.legal_reactions(game, "p2") == []
  end

  test "awaiting state excludes response players who already passed" do
    game =
      base_three_player_game(%{}, %{}, %{})
      |> Map.put(:phase, %{
        kind: :awaiting_action_responses,
        pending: pending_action("tax", :duke),
        eligible_ids: ["p2", "p3"],
        passed_ids: MapSet.new(["p2"])
      })

    awaiting = Game.awaiting(game)

    assert awaiting.kind == :action_response
    assert awaiting.actor_ids == ["p3"]
    refute awaiting.required?
    assert awaiting.actions == [:pass, :challenge]
    assert awaiting.subject.action == "tax"
    assert Game.legal_reactions(game, "p2") == []
    assert Game.legal_reactions(game, "p3") == [:pass, :challenge]
  end

  test "awaiting state exposes block responders" do
    pending = pending_action("foreign_aid", nil, [:duke])

    game =
      base_three_player_game(%{}, %{}, %{})
      |> Map.put(:phase, %{
        kind: :awaiting_block,
        pending: pending,
        eligible_ids: ["p2", "p3"],
        passed_ids: MapSet.new(["p3"])
      })

    assert Game.awaiting(game) == %{
             kind: :block,
             actor_ids: ["p2"],
             required?: false,
             actions: [:pass, :block],
             subject: pending
           }
  end

  test "awaiting state exposes challenge responses to a block" do
    pending = pending_action("steal", :captain, [:captain, :ambassador], "p2")
    block = %{player_id: "p2", role: :captain}

    game =
      base_three_player_game(%{}, %{}, %{})
      |> Map.put(:phase, %{
        kind: :awaiting_block_challenge,
        pending: pending,
        block: block,
        eligible_ids: ["p1", "p3"],
        passed_ids: MapSet.new(["p1"])
      })

    assert Game.awaiting(game) == %{
             kind: :block_response,
             actor_ids: ["p3"],
             required?: false,
             actions: [:pass, :challenge],
             subject: %{pending: pending, block: block}
           }
  end

  test "awaiting state exposes required reveal and exchange actors" do
    reveal_game =
      base_game(%{}, %{})
      |> Map.put(:phase, %{
        kind: :awaiting_reveal,
        player_id: "p2",
        reason: "Reveal one influence.",
        continuation: %{type: :advance_turn}
      })

    assert Game.awaiting(reveal_game) == %{
             kind: :reveal,
             actor_ids: ["p2"],
             required?: true,
             actions: [:reveal],
             subject: %{reason: "Reveal one influence."}
           }

    exchange_game =
      base_game(%{}, %{})
      |> Map.put(:phase, %{
        kind: :awaiting_exchange,
        player_id: "p1",
        options: [:duke, :captain, :assassin, :contessa],
        keep_count: 2,
        deck_rest: [:ambassador]
      })

    assert Game.awaiting(exchange_game) == %{
             kind: :exchange,
             actor_ids: ["p1"],
             required?: true,
             actions: [:exchange],
             subject: %{options: [:duke, :captain, :assassin, :contessa], keep_count: 2}
           }
  end

  test "successful challenge against a bluff block resumes and resolves original action" do
    game =
      base_three_player_game(
        %{},
        %{influences: [%{role: :assassin, revealed: false}, %{role: :contessa, revealed: false}]},
        %{}
      )

    assert {:ok, game} = Game.declare_action(game, "p1", "foreign_aid")
    assert {:ok, game} = Game.block(game, "p2", :duke)
    assert {:ok, game} = Game.challenge(game, "p3")

    assert game.phase.kind == :awaiting_reveal
    assert game.phase.player_id == "p2"

    assert {:ok, updated} = Game.reveal_influence(game, "p2", 0)

    assert updated.phase.kind == :awaiting_action
    assert updated.active_player_id == "p2"
    assert updated.turn_number == 2
    assert Enum.find(updated.players, &(&1.id == "p1")).coins == 4
    assert hd(updated.log).kind == :action
    assert hd(updated.log).verb == "unopposed"
    assert hd(updated.log).detail == "Foreign Aid stands"
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

  defp base_three_player_game(player_one_overrides, player_two_overrides, player_three_overrides) do
    %{
      status: :active,
      active_player_id: "p1",
      turn_number: 1,
      round_number: 1,
      treasury: 44,
      deck: [:duke, :captain, :ambassador, :contessa, :assassin, :duke],
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
        ),
        Map.merge(
          %{
            id: "p3",
            name: "Rhea",
            coins: 2,
            influences: [
              %{role: :ambassador, revealed: false},
              %{role: :captain, revealed: false}
            ]
          },
          player_three_overrides
        )
      ]
    }
  end

  defp pending_action(action, claim_role, block_roles \\ [], target_id \\ nil) do
    %{
      actor_id: "p1",
      actor_name: "Isolde",
      action: action,
      action_label: action_label(action),
      claim_role: claim_role,
      target_id: target_id,
      target_name: if(target_id, do: "Magnus", else: nil),
      block_roles: block_roles,
      block_candidates: if(target_id, do: [target_id], else: []),
      cost: 0
    }
  end

  defp action_label("foreign_aid"), do: "Foreign Aid"
  defp action_label(action), do: String.capitalize(action)
end
