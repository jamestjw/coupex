defmodule Coupex.Game do
  @moduledoc false

  alias Coupex.Game.Log
  alias Coupex.Game.Phase
  alias Coupex.Game.Player

  @roles [:duke, :assassin, :captain, :ambassador, :contessa]
  @treasury_coins 50
  @min_players 2
  @max_players 6

  @type role :: unquote(Enum.reduce(@roles, &{:|, [], [&1, &2]}))
  @type card :: %{required(:role) => role(), required(:revealed) => boolean()}
  @type game_player :: Player.t()

  # Covers :action, :challenge, :challenge_lost, :block, :challenge_won, :pass, :exchange, :game_over, :break, etc.
  @type log_entry :: %{required(:kind) => atom(), optional(atom()) => any()}

  # Phase kinds include :awaiting_action, :awaiting_action_responses, :awaiting_block, :awaiting_exchange, :game_over
  @typep phase_option ::
           {:pending, map()}
           | {:eligible_ids, [String.t()]}
           | {:passed_ids, map()}
           | {:exchange_cards, [card()]}
  @type phase :: %{required(:kind) => atom(), optional(phase_option()) => any()}

  @type t :: %{
          required(:status) => :active | :finished,
          required(:players) => [game_player()],
          required(:active_player_id) => String.t(),
          required(:turn_number) => non_neg_integer(),
          required(:round_number) => non_neg_integer(),
          required(:treasury) => non_neg_integer(),
          required(:deck) => [card()],
          required(:phase) => Phase.t(),
          required(:log) => [log_entry()],
          required(:winner_id) => String.t() | nil
        }

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

  @spec new([%{id: String.t(), name: String.t()}]) :: {:ok, t()} | {:error, String.t()}
  def new(players) when is_list(players) do
    if length(players) in @min_players..@max_players do
      deck = build_deck() |> Enum.shuffle()

      {game_players, deck_after_deal} =
        Enum.map_reduce(players, deck, fn player, acc_deck ->
          [first, second | rest] = acc_deck

          game_player = %Player{
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
         log: [Log.event(:break, %{text: "The court assembles"})],
         winner_id: nil
       }}
    else
      {:error, "Coup requires #{@min_players} to #{@max_players} players."}
    end
  end

  def declare_action(game, actor_id, action_id, target_id \\ nil) do
    Phase.module(game.phase).handle_action(game, actor_id, action_id, target_id)
  end

  def pass(game, player_id) do
    Phase.module(game.phase).handle_pass(game, player_id)
  end

  def challenge(game, challenger_id) do
    Phase.module(game.phase).handle_challenge(game, challenger_id)
  end

  def block(game, blocker_id, role) do
    Phase.module(game.phase).handle_block(game, blocker_id, role)
  end

  def reveal_influence(game, player_id, index) do
    Phase.module(game.phase).handle_reveal(game, player_id, index)
  end

  def choose_exchange(game, player_id, indexes) when is_list(indexes) do
    Phase.module(game.phase).handle_exchange(game, player_id, indexes)
  end

  def view(game, viewer_id) do
    players =
      Enum.map(game.players, fn player ->
        %{
          id: player.id,
          name: player.name,
          coins: player.coins,
          eliminated: Player.eliminated?(player),
          you: player.id == viewer_id,
          influences: visible_influences(player, viewer_id),
          alive_count: Player.alive_influence_count(player)
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

  def awaiting(game) do
    Phase.module(game.phase).awaiting(game)
  end

  def actors_waiting(game), do: awaiting(game).actor_ids

  def actor_waiting?(game, player_id), do: player_id in actors_waiting(game)

  def legal_reactions(game, player_id) do
    awaiting = awaiting(game)

    if player_id in awaiting.actor_ids, do: awaiting.actions, else: []
  end

  defp interaction(game, viewer_id) do
    Phase.module(game.phase).interaction(game, viewer_id)
  end

  @doc false
  def after_action_responses(game, pending) do
    # Players might have been eliminated during action responses, i.e. we need
    # to recalculate block_candidates
    block_candidates =
      Phase.block_candidates(game, pending.actor_id, pending.action, pending.target_id)

    pending = %{pending | block_candidates: block_candidates}

    if pending.block_roles == [] or block_candidates == [] do
      {:ok, resolve_and_advance(game, pending)}
    else
      # Moving on to blocking phase
      {:ok,
       put_phase(game, %{
         kind: :awaiting_block,
         pending: pending,
         eligible_ids: pending.block_candidates,
         passed_ids: MapSet.new()
       })}
    end
  end

  @doc false
  def resolve_challenge(game, challenger_id, claimed_by_id, role, continuations) do
    truthful = has_unrevealed_role?(game, claimed_by_id, role)

    game =
      Log.push_log(
        game,
        Log.event(:challenge, %{
          actor: player_name(game, challenger_id),
          target: player_name(game, claimed_by_id),
          role: Log.role_label(role),
          truthful: truthful
        })
      )

    if truthful do
      game = replace_proven_role(game, claimed_by_id, role)

      game =
        Log.push_log(
          game,
          Log.event(:exchange, %{
            actor: player_name(game, claimed_by_id),
            detail: "revealed #{Log.role_label(role)} and exchanged it for a new influence."
          })
        )

      {:ok,
       begin_reveal_phase(
         game,
         challenger_id,
         "Your challenge failed. Reveal one influence.",
         continuations.success
       )}
    else
      {:ok,
       begin_reveal_phase(
         game,
         claimed_by_id,
         "Your bluff was caught. Reveal one influence.",
         continuations.failure
       )}
    end
  end

  @doc false
  def continue_after_reveal(game, continuation) do
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

  @doc false
  def resolve_action(game, pending) do
    case pending.action do
      "foreign_aid" ->
        game
        |> resolve_income(pending.actor_id, 2)
        |> Log.log_action_resolution(pending, %{gained: 2})

      "tax" ->
        game
        |> resolve_income(pending.actor_id, 3)
        |> Log.log_action_resolution(pending, %{gained: 3})

      "steal" ->
        {game, amount} = resolve_steal(game, pending.actor_id, pending.target_id)
        Log.log_action_resolution(game, pending, %{gained: amount, lost: amount})

      "assassinate" ->
        if Player.eliminated?(Player.fetch!(game.players, pending.target_id)) do
          # Maybe the player challenged the assassination and failed, and hence is
          # already eliminated, there is nothing we need to do here.
          game
        else
          begin_reveal_phase(
            game,
            pending.target_id,
            "Choose an influence to lose to the assassination.",
            %{type: :advance_turn}
          )
        end

      "exchange" ->
        begin_exchange(game, pending.actor_id)
    end
  end

  defp begin_exchange(game, player_id) do
    player = Player.fetch!(game.players, player_id)
    keep_count = Player.alive_influence_count(player)
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

  @doc false
  def resolve_income(game, player_id, amount) do
    game
    |> update_player(player_id, fn player -> %{player | coins: player.coins + amount} end)
    |> Map.update!(:treasury, &max(&1 - amount, 0))
  end

  defp resolve_steal(game, actor_id, target_id) do
    target = Player.fetch!(game.players, target_id)
    amount = min(target.coins, 2)

    updated_game =
      game
      |> update_player(actor_id, fn player -> %{player | coins: player.coins + amount} end)
      |> update_player(target_id, fn player -> %{player | coins: player.coins - amount} end)

    {updated_game, amount}
  end

  @doc false
  def begin_reveal_phase(game, player_id, reason, continuation) do
    case single_unrevealed_influence_index(game, player_id) do
      {:ok, index} ->
        game = reveal_player_influence(game, player_id, index)
        game = check_winner(game)

        if game.status == :finished do
          put_phase(game, %{kind: :game_over})
        else
          {:ok, next_game} = continue_after_reveal(game, continuation)
          next_game
        end

      :multiple_or_none ->
        put_phase(game, %{
          kind: :awaiting_reveal,
          player_id: player_id,
          reason: reason,
          continuation: continuation
        })
    end
  end

  # Returns {:ok, index} only when exactly one unrevealed influence remains.
  # We return :multiple_or_none for all other cases to explicitly route to
  # the regular reveal-choice flow without auto-selecting a card.
  defp single_unrevealed_influence_index(game, player_id) do
    indexes =
      game.players
      |> Player.fetch!(player_id)
      |> Map.fetch!(:influences)
      |> Enum.with_index()
      |> Enum.filter(fn {influence, _index} -> not influence.revealed end)
      |> Enum.map(fn {_influence, index} -> index end)

    case indexes do
      [index] -> {:ok, index}
      _ -> :multiple_or_none
    end
  end

  @doc false
  def resolve_and_advance(game, pending) do
    game
    |> Map.put(:phase, %{kind: :awaiting_action})
    |> resolve_action(pending)
    |> after_resolution()
  end

  @doc false
  def advance_or_finish(game) do
    game
    |> check_winner()
    |> advance_turn_if_active()
  end

  @doc false
  def after_resolution(%{phase: %{kind: :awaiting_action}} = game), do: advance_or_finish(game)
  @doc false
  def after_resolution(game), do: game

  defp advance_turn_if_active(%{status: :finished} = game),
    do: put_phase(game, %{kind: :game_over})

  defp advance_turn_if_active(game) do
    players = game.players
    current_index = Enum.find_index(players, &(&1.id == game.active_player_id)) || 0

    next_index =
      1..length(players)
      |> Enum.find(fn step ->
        candidate = Enum.at(players, rem(current_index + step, length(players)))
        candidate && not Player.eliminated?(candidate)
      end)

    next_player = Enum.at(players, rem(current_index + next_index, length(players)))

    round_number =
      if rem(current_index + next_index, length(players)) <= current_index do
        game.round_number + 1
      else
        game.round_number
      end

    advanced =
      %{
        game
        | active_player_id: next_player.id,
          turn_number: game.turn_number + 1,
          round_number: round_number,
          phase: %{kind: :awaiting_action}
      }

    if round_number > game.round_number do
      Log.push_log(advanced, Log.event(:break, %{text: "Round #{round_number}"}))
    else
      advanced
    end
  end

  @doc false
  def check_winner(game) do
    alive_players = Enum.reject(game.players, &Player.eliminated?/1)

    case alive_players do
      [winner] ->
        game
        |> Log.push_log(Log.event(:win, %{actor: winner.name, detail: "claims the court"}))
        |> Map.put(:winner_id, winner.id)
        |> Map.put(:status, :finished)

      _ ->
        game
    end
  end

  @doc false
  def put_phase(game, phase), do: %{game | phase: phase}

  @doc false
  def pay_cost(game, _player_id, 0), do: game

  @doc false
  def pay_cost(game, player_id, cost) do
    game
    |> update_player(player_id, fn player -> %{player | coins: player.coins - cost} end)
    |> Map.update!(:treasury, &(&1 + cost))
  end

  defp replace_proven_role(game, player_id, role) do
    player = Player.fetch!(game.players, player_id)
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

  @doc false
  def reveal_player_influence(game, player_id, index) do
    player = Player.fetch!(game.players, player_id)
    influence = Enum.at(player.influences, index)
    updated_influences = List.replace_at(player.influences, index, %{influence | revealed: true})
    updated_player = %{player | influences: updated_influences}

    game
    |> replace_player(updated_player)
    |> Log.push_log(
      Log.event(:reveal, %{
        actor: player.name,
        role: Log.role_label(influence.role),
        detail: "loses influence"
      })
    )
  end

  defp available_actions(game, viewer_id) do
    if game.status != :active or game.phase.kind != :awaiting_action or
         game.active_player_id != viewer_id do
      []
    else
      player = Player.fetch!(game.players, viewer_id)
      forced_coup = player.coins >= 10

      action_specs()
      |> Enum.map(fn spec ->
        enough_coins = player.coins >= spec.cost
        disabled = not ((not forced_coup or spec.id == "coup") and enough_coins)

        spec
        |> Map.put(:disabled, disabled)
        |> Map.put(:targets, if(spec.target, do: available_targets(game, viewer_id), else: []))
      end)
    end
  end

  defp available_targets(game, viewer_id) do
    game.players
    |> Enum.reject(&(&1.id == viewer_id or Player.eliminated?(&1)))
    |> Enum.map(&%{id: &1.id, name: &1.name})
  end

  defp visible_influences(player, viewer_id) do
    Enum.map(player.influences, fn influence ->
      cond do
        player.id == viewer_id ->
          %{role: Log.role_label(influence.role), revealed: influence.revealed, hidden: false}

        influence.revealed ->
          %{role: Log.role_label(influence.role), revealed: true, hidden: false}

        true ->
          %{role: nil, revealed: false, hidden: true}
      end
    end)
  end

  @doc false
  def public_pending(pending) do
    %{
      actor_id: pending.actor_id,
      actor_name: pending.actor_name,
      action: pending.action,
      action_label: pending.action_label,
      claim_role: pending.claim_role && Log.role_label(pending.claim_role),
      target_id: pending.target_id,
      target_name: pending.target_name,
      block_roles: Enum.map(pending.block_roles, &Log.role_label/1)
    }
  end

  @doc false
  def remaining_eligible_ids(%{eligible_ids: eligible_ids, passed_ids: passed_ids}) do
    Enum.reject(eligible_ids, &MapSet.member?(passed_ids, &1))
  end

  defp build_deck, do: Enum.flat_map(@roles, &List.duplicate(&1, 3))

  @doc false
  def fetch_action(action_id) do
    case Enum.find(action_specs(), &(&1.id == action_id)) do
      nil -> {:error, "Unknown action."}
      spec -> {:ok, spec}
    end
  end

  defp hidden_roles(player) do
    player.influences
    |> Enum.reject(& &1.revealed)
    |> Enum.map(& &1.role)
  end

  defp has_unrevealed_role?(game, player_id, role) do
    game
    |> Map.fetch!(:players)
    |> Player.fetch!(player_id)
    |> hidden_roles()
    |> Enum.member?(role)
  end

  @doc false
  def alive_other_player_ids(game, player_id) do
    game.players
    |> Enum.reject(&(&1.id == player_id or Player.eliminated?(&1)))
    |> Enum.map(& &1.id)
  end

  @doc false
  def update_player(game, player_id, fun) do
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

  @doc false
  def player_name(game, player_id), do: Player.fetch!(game.players, player_id).name
  @doc false
  def target_name(_game, nil), do: nil
  @doc false
  def target_name(game, target_id), do: player_name(game, target_id)

  @doc false
  def list_difference(items, selected) do
    Enum.reduce(selected, items, fn value, acc -> List.delete(acc, value) end)
  end
end
