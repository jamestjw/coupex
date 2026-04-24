defmodule Coupex.Game do
  @moduledoc false

  @roles [:duke, :assassin, :captain, :ambassador, :contessa]
  @treasury_coins 50

  def roles, do: @roles

  def action_specs do
    [
      %{id: "income", label: "Income", detail: "Take 1 coin", claim: nil, cost: 0, target: false},
      %{
        id: "foreign_aid",
        label: "Foreign Aid",
        detail: "Take 2 coins",
        claim: nil,
        cost: 0,
        target: false
      },
      %{
        id: "tax",
        label: "Tax",
        detail: "Claim Duke for 3 coins",
        claim: :duke,
        cost: 0,
        target: false
      },
      %{
        id: "assassinate",
        label: "Assassinate",
        detail: "Claim Assassin and pay 3",
        claim: :assassin,
        cost: 3,
        target: true
      },
      %{
        id: "steal",
        label: "Steal",
        detail: "Claim Captain to take 2",
        claim: :captain,
        cost: 0,
        target: true
      },
      %{
        id: "exchange",
        label: "Exchange",
        detail: "Claim Ambassador to redraw",
        claim: :ambassador,
        cost: 0,
        target: false
      },
      %{
        id: "coup",
        label: "Coup",
        detail: "Pay 7 to force influence loss",
        claim: nil,
        cost: 7,
        target: true
      }
    ]
  end

  def new(players) when is_list(players) do
    if length(players) in 2..6 do
      deck = build_deck() |> Enum.shuffle()

      {game_players, deck_after_deal} =
        Enum.map_reduce(players, deck, fn player, acc_deck ->
          [first, second | rest] = acc_deck

          game_player = %{
            id: player.id,
            name: player.name,
            coins: 2,
            influences: [
              %{role: first, revealed: false},
              %{role: second, revealed: false}
            ]
          }

          {game_player, rest}
        end)

      {:ok,
       %{
         status: :active,
         players: game_players,
         active_player_id: hd(game_players).id,
         turn_number: 1,
         round_number: 1,
         treasury: @treasury_coins - length(game_players) * 2,
         deck: deck_after_deal,
         phase: %{kind: :awaiting_action},
         log: [event(:break, %{text: "The court assembles"})],
         winner_id: nil
       }}
    else
      {:error, "Coup requires 2 to 6 players."}
    end
  end

  def declare_action(game, actor_id, action_id, target_id \\ nil) do
    with :ok <- ensure_active(game),
         :ok <- ensure_turn(game, actor_id),
         :ok <- ensure_phase(game, :awaiting_action),
         {:ok, spec} <- fetch_action(action_id),
         :ok <- ensure_action_allowed(game, actor_id, spec),
         :ok <- ensure_target(game, actor_id, spec, target_id) do
      pending = %{
        actor_id: actor_id,
        actor_name: player_name(game, actor_id),
        action: spec.id,
        action_label: spec.label,
        claim_role: spec.claim,
        target_id: target_id,
        target_name: target_name(game, target_id),
        block_roles: block_roles(spec.id),
        block_candidates: block_candidates(game, actor_id, spec.id, target_id),
        cost: spec.cost
      }

      game = pay_cost(game, actor_id, spec.cost)
      game = push_log(game, event(:action, describe_action(pending)))

      cond do
        spec.id == "income" ->
          {:ok, advance_or_finish(resolve_income(game, actor_id, 1))}

        spec.id == "coup" ->
          {:ok,
           put_phase(game, %{
             kind: :awaiting_reveal,
             player_id: target_id,
             reason: "Choose an influence to lose to the coup.",
             continuation: %{type: :advance_turn}
           })}

        spec.claim != nil ->
          {:ok,
           put_phase(game, %{
             kind: :awaiting_action_responses,
             pending: pending,
             eligible_ids: alive_other_player_ids(game, actor_id),
             passed_ids: MapSet.new()
           })}

        pending.block_roles == [] ->
          {:ok, after_resolution(resolve_action(game, pending))}

        true ->
          {:ok,
           put_phase(game, %{
             kind: :awaiting_block,
             pending: pending,
             eligible_ids: pending.block_candidates,
             passed_ids: MapSet.new()
           })}
      end
    end
  end

  def pass(game, player_id) do
    case game.phase do
      %{
        kind: :awaiting_action_responses,
        eligible_ids: eligible_ids,
        passed_ids: passed_ids,
        pending: pending
      } ->
        with :ok <- ensure_member(eligible_ids, player_id) do
          next_passed = MapSet.put(passed_ids, player_id)

          if Enum.all?(eligible_ids, &MapSet.member?(next_passed, &1)) do
            after_action_responses(game, pending)
          else
            {:ok, %{game | phase: %{game.phase | passed_ids: next_passed}}}
          end
        end

      %{
        kind: :awaiting_block,
        eligible_ids: eligible_ids,
        passed_ids: passed_ids,
        pending: pending
      } ->
        with :ok <- ensure_member(eligible_ids, player_id) do
          next_passed = MapSet.put(passed_ids, player_id)

          if Enum.all?(eligible_ids, &MapSet.member?(next_passed, &1)) do
            {:ok, after_resolution(resolve_action(game, pending))}
          else
            {:ok, %{game | phase: %{game.phase | passed_ids: next_passed}}}
          end
        end

      %{
        kind: :awaiting_block_challenge,
        eligible_ids: eligible_ids,
        passed_ids: passed_ids,
        block: block
      } ->
        with :ok <- ensure_member(eligible_ids, player_id) do
          next_passed = MapSet.put(passed_ids, player_id)

          if Enum.all?(eligible_ids, &MapSet.member?(next_passed, &1)) do
            game =
              push_log(
                game,
                event(:block, %{
                  actor: player_name(game, block.player_id),
                  detail: "held the block"
                })
              )

            {:ok, advance_or_finish(%{game | phase: %{kind: :awaiting_action}})}
          else
            {:ok, %{game | phase: %{game.phase | passed_ids: next_passed}}}
          end
        end

      _ ->
        {:error, "There is nothing to pass on right now."}
    end
  end

  def challenge(game, challenger_id) do
    case game.phase do
      %{kind: :awaiting_action_responses, eligible_ids: eligible_ids, pending: pending} ->
        with :ok <- ensure_member(eligible_ids, challenger_id) do
          resolve_challenge(game, challenger_id, pending.actor_id, pending.claim_role, %{
            success: %{type: :continue_after_failed_action_challenge, pending: pending},
            failure: %{type: :cancel_after_successful_action_challenge}
          })
        end

      %{
        kind: :awaiting_block_challenge,
        eligible_ids: eligible_ids,
        pending: pending,
        block: block
      } ->
        with :ok <- ensure_member(eligible_ids, challenger_id) do
          resolve_challenge(game, challenger_id, block.player_id, block.role, %{
            success: %{type: :block_stands},
            failure: %{type: :resume_after_successful_block_challenge, pending: pending}
          })
        end

      _ ->
        {:error, "There is no claim to challenge right now."}
    end
  end

  def block(game, blocker_id, role) do
    case game.phase do
      %{kind: :awaiting_block, pending: pending, eligible_ids: eligible_ids} ->
        with :ok <- ensure_member(eligible_ids, blocker_id),
             :ok <- ensure_block_role(pending.action, role) do
          block = %{player_id: blocker_id, role: role}

          game =
            push_log(
              game,
              event(:block, %{
                actor: player_name(game, blocker_id),
                role: role_label(role),
                detail: "blocked #{pending.action_label}"
              })
            )

          {:ok,
           put_phase(game, %{
             kind: :awaiting_block_challenge,
             pending: pending,
             block: block,
             eligible_ids: alive_other_player_ids(game, blocker_id),
             passed_ids: MapSet.new()
           })}
        end

      _ ->
        {:error, "You cannot block right now."}
    end
  end

  def reveal_influence(game, player_id, index) do
    case game.phase do
      %{kind: :awaiting_reveal, player_id: ^player_id, continuation: continuation} ->
        with :ok <- ensure_reveal_index(game, player_id, index) do
          game = reveal_player_influence(game, player_id, index)
          game = check_winner(game)

          if game.status == :finished do
            {:ok, put_phase(game, %{kind: :game_over})}
          else
            continue_after_reveal(game, continuation)
          end
        end

      %{kind: :awaiting_reveal} ->
        {:error, "Another player must choose an influence first."}

      _ ->
        {:error, "No reveal is pending."}
    end
  end

  def choose_exchange(game, player_id, indexes) when is_list(indexes) do
    case game.phase do
      %{
        kind: :awaiting_exchange,
        player_id: ^player_id,
        options: options,
        keep_count: keep_count,
        deck_rest: deck_rest
      } ->
        indexes = Enum.uniq(indexes)

        with :ok <- ensure_exchange_indexes(options, indexes, keep_count) do
          kept = Enum.map(indexes, &Enum.at(options, &1))
          returned = list_difference(options, kept)

          game =
            update_player(game, player_id, fn player ->
              revealed = Enum.filter(player.influences, & &1.revealed)
              hidden = Enum.map(kept, &%{role: &1, revealed: false})
              %{player | influences: revealed ++ hidden}
            end)

          game = %{game | deck: Enum.shuffle(deck_rest ++ returned)}

          game =
            push_log(
              game,
              event(:exchange, %{
                actor: player_name(game, player_id),
                detail: "rearranged the court"
              })
            )

          {:ok, advance_or_finish(%{game | phase: %{kind: :awaiting_action}})}
        end

      %{kind: :awaiting_exchange} ->
        {:error, "Another player is exchanging cards right now."}

      _ ->
        {:error, "There is no exchange to resolve."}
    end
  end

  def view(game, viewer_id) do
    players =
      Enum.map(game.players, fn player ->
        %{
          id: player.id,
          name: player.name,
          coins: player.coins,
          eliminated: eliminated?(player),
          you: player.id == viewer_id,
          influences: visible_influences(player, viewer_id),
          alive_count: alive_influence_count(player)
        }
      end)

    you = Enum.find(players, &(&1.id == viewer_id))

    %{
      status: game.status,
      players: players,
      active_player_id: game.active_player_id,
      active_player_name: player_name(game, game.active_player_id),
      turn_number: game.turn_number,
      round_number: game.round_number,
      deck_count: length(game.deck),
      treasury: game.treasury,
      log: Enum.reverse(game.log),
      winner_id: game.winner_id,
      you: Map.put(you || %{}, :available_actions, available_actions(game, viewer_id)),
      interaction: interaction(game, viewer_id)
    }
  end

  defp interaction(game, viewer_id) do
    case game.phase do
      %{kind: :awaiting_action} ->
        %{kind: :action, your_turn: viewer_id == game.active_player_id}

      %{
        kind: :awaiting_action_responses,
        pending: pending,
        eligible_ids: eligible_ids,
        passed_ids: passed_ids
      } ->
        %{
          kind: :respond_action,
          pending: public_pending(pending),
          can_challenge: viewer_id in eligible_ids and not MapSet.member?(passed_ids, viewer_id),
          can_pass: viewer_id in eligible_ids and not MapSet.member?(passed_ids, viewer_id)
        }

      %{
        kind: :awaiting_block,
        pending: pending,
        eligible_ids: eligible_ids,
        passed_ids: passed_ids
      } ->
        block_roles =
          if viewer_id in eligible_ids and not MapSet.member?(passed_ids, viewer_id),
            do: pending.block_roles,
            else: []

        %{
          kind: :block,
          pending: public_pending(pending),
          block_roles: Enum.map(block_roles, &role_label/1),
          block_role_ids: Enum.map(block_roles, &Atom.to_string/1),
          can_pass: viewer_id in eligible_ids and not MapSet.member?(passed_ids, viewer_id)
        }

      %{
        kind: :awaiting_block_challenge,
        pending: pending,
        block: block,
        eligible_ids: eligible_ids,
        passed_ids: passed_ids
      } ->
        %{
          kind: :respond_block,
          pending: public_pending(pending),
          block: %{
            player_id: block.player_id,
            player_name: player_name(game, block.player_id),
            role: role_label(block.role)
          },
          can_challenge: viewer_id in eligible_ids and not MapSet.member?(passed_ids, viewer_id),
          can_pass: viewer_id in eligible_ids and not MapSet.member?(passed_ids, viewer_id)
        }

      %{kind: :awaiting_reveal, player_id: player_id, reason: reason} ->
        %{kind: :reveal, reason: reason, your_turn: viewer_id == player_id}

      %{kind: :awaiting_exchange, player_id: player_id, options: options, keep_count: keep_count} ->
        %{
          kind: :exchange,
          your_turn: viewer_id == player_id,
          keep_count: keep_count,
          options: if(viewer_id == player_id, do: Enum.map(options, &role_label/1), else: [])
        }

      %{kind: :game_over} ->
        %{kind: :game_over}
    end
  end

  defp after_action_responses(game, pending) do
    if pending.block_roles == [] do
      {:ok, after_resolution(resolve_action(game, pending))}
    else
      {:ok,
       put_phase(game, %{
         kind: :awaiting_block,
         pending: pending,
         eligible_ids: pending.block_candidates,
         passed_ids: MapSet.new()
       })}
    end
  end

  defp resolve_challenge(game, challenger_id, claimed_by_id, role, continuations) do
    truthful = has_unrevealed_role?(game, claimed_by_id, role)

    game =
      push_log(
        game,
        event(:challenge, %{
          actor: player_name(game, challenger_id),
          target: player_name(game, claimed_by_id),
          role: role_label(role),
          truthful: truthful
        })
      )

    if truthful do
      game = replace_proven_role(game, claimed_by_id, role)

      {:ok,
       put_phase(game, %{
         kind: :awaiting_reveal,
         player_id: challenger_id,
         reason: "Your challenge failed. Reveal one influence.",
         continuation: continuations.success
       })}
    else
      {:ok,
       put_phase(game, %{
         kind: :awaiting_reveal,
         player_id: claimed_by_id,
         reason: "Your bluff was caught. Reveal one influence.",
         continuation: continuations.failure
       })}
    end
  end

  defp continue_after_reveal(game, continuation) do
    case continuation.type do
      :advance_turn ->
        {:ok, advance_or_finish(%{game | phase: %{kind: :awaiting_action}})}

      :continue_after_failed_action_challenge ->
        pending = continuation.pending
        after_action_responses(%{game | phase: %{kind: :awaiting_action}}, pending)

      :cancel_after_successful_action_challenge ->
        {:ok, advance_or_finish(%{game | phase: %{kind: :awaiting_action}})}

      :resume_after_successful_block_challenge ->
        pending = continuation.pending

        {:ok,
         after_resolution(resolve_action(%{game | phase: %{kind: :awaiting_action}}, pending))}

      :block_stands ->
        {:ok, advance_or_finish(%{game | phase: %{kind: :awaiting_action}})}
    end
  end

  defp resolve_action(game, pending) do
    case pending.action do
      "foreign_aid" ->
        resolve_income(game, pending.actor_id, 2)

      "tax" ->
        resolve_income(game, pending.actor_id, 3)

      "steal" ->
        resolve_steal(game, pending.actor_id, pending.target_id)

      "assassinate" ->
        put_phase(game, %{
          kind: :awaiting_reveal,
          player_id: pending.target_id,
          reason: "Choose an influence to lose to the assassination.",
          continuation: %{type: :advance_turn}
        })

      "exchange" ->
        begin_exchange(game, pending.actor_id)
    end
  end

  defp begin_exchange(game, player_id) do
    player = fetch_player!(game, player_id)
    keep_count = alive_influence_count(player)
    {drawn, deck_rest} = Enum.split(game.deck, min(2, length(game.deck)))
    options = hidden_roles(player) ++ drawn

    put_phase(game, %{
      kind: :awaiting_exchange,
      player_id: player_id,
      keep_count: keep_count,
      options: options,
      deck_rest: deck_rest
    })
  end

  defp resolve_income(game, player_id, amount) do
    game
    |> update_player(player_id, fn player -> %{player | coins: player.coins + amount} end)
    |> Map.update!(:treasury, &max(&1 - amount, 0))
  end

  defp resolve_steal(game, actor_id, target_id) do
    target = fetch_player!(game, target_id)
    amount = min(target.coins, 2)

    game
    |> update_player(actor_id, fn player -> %{player | coins: player.coins + amount} end)
    |> update_player(target_id, fn player -> %{player | coins: player.coins - amount} end)
  end

  defp advance_or_finish(game) do
    game
    |> check_winner()
    |> advance_turn_if_active()
  end

  defp after_resolution(%{phase: %{kind: :awaiting_action}} = game), do: advance_or_finish(game)
  defp after_resolution(game), do: game

  defp advance_turn_if_active(%{status: :finished} = game),
    do: put_phase(game, %{kind: :game_over})

  defp advance_turn_if_active(game) do
    players = game.players
    current_index = Enum.find_index(players, &(&1.id == game.active_player_id)) || 0

    next_index =
      1..length(players)
      |> Enum.find(fn step ->
        candidate = Enum.at(players, rem(current_index + step, length(players)))
        candidate && not eliminated?(candidate)
      end)

    next_player = Enum.at(players, rem(current_index + next_index, length(players)))

    round_number =
      if rem(current_index + next_index, length(players)) <= current_index do
        game.round_number + 1
      else
        game.round_number
      end

    %{
      game
      | active_player_id: next_player.id,
        turn_number: game.turn_number + 1,
        round_number: round_number,
        phase: %{kind: :awaiting_action}
    }
  end

  defp check_winner(game) do
    alive_players = Enum.reject(game.players, &eliminated?/1)

    case alive_players do
      [winner] ->
        game
        |> push_log(event(:win, %{actor: winner.name, detail: "claims the court"}))
        |> Map.put(:winner_id, winner.id)
        |> Map.put(:status, :finished)

      _ ->
        game
    end
  end

  defp put_phase(game, phase), do: %{game | phase: phase}

  defp pay_cost(game, _player_id, 0), do: game

  defp pay_cost(game, player_id, cost) do
    game
    |> update_player(player_id, fn player -> %{player | coins: player.coins - cost} end)
    |> Map.update!(:treasury, &(&1 + cost))
  end

  defp replace_proven_role(game, player_id, role) do
    player = fetch_player!(game, player_id)
    hidden = hidden_roles(player)
    kept_hidden = List.delete(hidden, role)
    deck = Enum.shuffle([role | game.deck])
    [replacement | rest] = deck

    updated_player =
      player
      |> Map.put(
        :influences,
        Enum.filter(player.influences, & &1.revealed) ++
          Enum.map([replacement | kept_hidden], &%{role: &1, revealed: false})
      )

    game
    |> replace_player(updated_player)
    |> Map.put(:deck, rest)
  end

  defp reveal_player_influence(game, player_id, index) do
    player = fetch_player!(game, player_id)
    influence = Enum.at(player.influences, index)
    updated_influences = List.replace_at(player.influences, index, %{influence | revealed: true})
    updated_player = %{player | influences: updated_influences}

    game
    |> replace_player(updated_player)
    |> push_log(
      event(:reveal, %{
        actor: player.name,
        role: role_label(influence.role),
        detail: "loses influence"
      })
    )
  end

  defp available_actions(game, viewer_id) do
    if game.status != :active or game.phase.kind != :awaiting_action or
         game.active_player_id != viewer_id do
      []
    else
      player = fetch_player!(game, viewer_id)
      forced_coup = player.coins >= 10

      action_specs()
      |> Enum.filter(fn spec ->
        enough_coins = player.coins >= spec.cost
        (not forced_coup or spec.id == "coup") and enough_coins
      end)
      |> Enum.map(fn spec ->
        Map.put(spec, :targets, if(spec.target, do: available_targets(game, viewer_id), else: []))
      end)
    end
  end

  defp available_targets(game, viewer_id) do
    game.players
    |> Enum.reject(&(&1.id == viewer_id or eliminated?(&1)))
    |> Enum.map(&%{id: &1.id, name: &1.name})
  end

  defp visible_influences(player, viewer_id) do
    Enum.map(player.influences, fn influence ->
      cond do
        player.id == viewer_id ->
          %{role: role_label(influence.role), revealed: influence.revealed, hidden: false}

        influence.revealed ->
          %{role: role_label(influence.role), revealed: true, hidden: false}

        true ->
          %{role: nil, revealed: false, hidden: true}
      end
    end)
  end

  defp public_pending(pending) do
    %{
      actor_id: pending.actor_id,
      actor_name: pending.actor_name,
      action: pending.action,
      action_label: pending.action_label,
      claim_role: pending.claim_role && role_label(pending.claim_role),
      target_id: pending.target_id,
      target_name: pending.target_name,
      block_roles: Enum.map(pending.block_roles, &role_label/1)
    }
  end

  defp describe_action(pending) do
    base = %{actor: pending.actor_name, detail: pending.action_label, target: pending.target_name}
    if pending.claim_role, do: Map.put(base, :role, role_label(pending.claim_role)), else: base
  end

  defp build_deck, do: Enum.flat_map(@roles, &List.duplicate(&1, 3))

  defp fetch_action(action_id) do
    case Enum.find(action_specs(), &(&1.id == action_id)) do
      nil -> {:error, "Unknown action."}
      spec -> {:ok, spec}
    end
  end

  defp block_roles("foreign_aid"), do: [:duke]
  defp block_roles("assassinate"), do: [:contessa]
  defp block_roles("steal"), do: [:captain, :ambassador]
  defp block_roles(_), do: []

  defp block_candidates(game, actor_id, "foreign_aid", _target_id),
    do: alive_other_player_ids(game, actor_id)

  defp block_candidates(_game, _actor_id, action, target_id)
       when action in ["assassinate", "steal"], do: [target_id]

  defp block_candidates(_game, _actor_id, _action, _target_id), do: []

  defp hidden_roles(player) do
    player.influences
    |> Enum.reject(& &1.revealed)
    |> Enum.map(& &1.role)
  end

  defp alive_influence_count(player), do: Enum.count(player.influences, &(not &1.revealed))
  defp eliminated?(player), do: alive_influence_count(player) == 0

  defp ensure_active(%{status: :active}), do: :ok
  defp ensure_active(_game), do: {:error, "The game is over."}

  defp ensure_turn(game, player_id) do
    if game.active_player_id == player_id, do: :ok, else: {:error, "It is not your turn."}
  end

  defp ensure_phase(game, expected_kind) do
    if game.phase.kind == expected_kind,
      do: :ok,
      else: {:error, "That action is not available right now."}
  end

  defp ensure_action_allowed(game, player_id, spec) do
    player = fetch_player!(game, player_id)

    cond do
      player.coins >= 10 and spec.id != "coup" ->
        {:error, "You must coup when you have 10 or more coins."}

      player.coins < spec.cost ->
        {:error, "You do not have enough coins."}

      true ->
        :ok
    end
  end

  defp ensure_target(_game, _actor_id, %{target: false}, nil), do: :ok

  defp ensure_target(game, actor_id, %{target: true}, target_id) do
    cond do
      is_nil(target_id) ->
        {:error, "Choose a target."}

      actor_id == target_id ->
        {:error, "You cannot target yourself."}

      is_nil(Enum.find(game.players, &(&1.id == target_id and not eliminated?(&1)))) ->
        {:error, "Choose a living target."}

      true ->
        :ok
    end
  end

  defp ensure_target(_game, _actor_id, _spec, _target_id),
    do: {:error, "This action does not take a target."}

  defp ensure_member(list, player_id) do
    if player_id in list, do: :ok, else: {:error, "You cannot respond here."}
  end

  defp ensure_block_role(action, role) when is_binary(role),
    do: ensure_block_role(action, String.to_existing_atom(role))

  defp ensure_block_role(action, role),
    do:
      if(role in block_roles(action),
        do: :ok,
        else: {:error, "That role cannot block this action."}
      )

  defp ensure_reveal_index(game, player_id, index) do
    player = fetch_player!(game, player_id)
    influence = Enum.at(player.influences, index)

    cond do
      is_nil(influence) -> {:error, "Choose one of your influences."}
      influence.revealed -> {:error, "That influence is already revealed."}
      true -> :ok
    end
  end

  defp ensure_exchange_indexes(options, indexes, keep_count) do
    valid = Enum.all?(indexes, &(&1 >= 0 and &1 < length(options)))

    cond do
      length(indexes) != keep_count -> {:error, "Choose exactly #{keep_count} cards to keep."}
      not valid -> {:error, "Choose valid exchange cards."}
      true -> :ok
    end
  end

  defp has_unrevealed_role?(game, player_id, role) do
    game
    |> fetch_player!(player_id)
    |> hidden_roles()
    |> Enum.member?(role)
  end

  defp alive_other_player_ids(game, player_id) do
    game.players
    |> Enum.reject(&(&1.id == player_id or eliminated?(&1)))
    |> Enum.map(& &1.id)
  end

  defp update_player(game, player_id, fun) do
    updated_players =
      Enum.map(game.players, fn player ->
        if player.id == player_id, do: fun.(player), else: player
      end)

    %{game | players: updated_players}
  end

  defp replace_player(game, updated_player) do
    %{
      game
      | players:
          Enum.map(game.players, fn player ->
            if player.id == updated_player.id, do: updated_player, else: player
          end)
    }
  end

  defp fetch_player!(game, player_id) do
    Enum.find(game.players, &(&1.id == player_id)) || raise "missing player #{player_id}"
  end

  defp player_name(game, player_id), do: fetch_player!(game, player_id).name
  defp target_name(_game, nil), do: nil
  defp target_name(game, target_id), do: player_name(game, target_id)

  defp push_log(game, entry), do: %{game | log: [entry | game.log]}
  defp event(kind, attrs), do: Map.put(attrs, :kind, kind)

  defp role_label(role) do
    role
    |> Atom.to_string()
    |> String.capitalize()
  end

  defp list_difference(items, selected) do
    Enum.reduce(selected, items, fn value, acc -> List.delete(acc, value) end)
  end
end
