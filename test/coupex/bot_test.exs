defmodule Coupex.BotTest do
  use ExUnit.Case, async: true

  alias Coupex.Bot
  alias Coupex.Bot.Native
  alias Coupex.Game

  test "native rusty-duke chooser returns a move" do
    payload = %{
      strategy: "heuristic",
      profile: "balanced",
      seed: 1,
      viewer: 0,
      deck_size: 11,
      own_hidden_cards: ["duke", "contessa"],
      players: [
        %{coins: 2, hidden_influence: 2, revealed: [], alive: true},
        %{coins: 2, hidden_influence: 2, revealed: [], alive: true}
      ],
      phase: %{kind: "action", actor: 0}
    }

    assert {:ok, encoded_move} = payload |> Jason.encode!() |> Native.choose_move()
    assert {:ok, %{"kind" => "take_action"}} = Jason.decode(encoded_move)
  end

  test "chooses tax when holding duke" do
    {:ok, game} =
      Game.new([
        %{id: "player-one", name: "Player 1"},
        %{id: "player-two", name: "Player 2"}
      ])

    [player_one, player_two] = game.players

    game =
      %{
        game
        | players: [
            %{
              player_one
              | coins: 2,
                influences: [%{role: :duke, revealed: false}, %{role: :contessa, revealed: false}]
            },
            %{
              player_two
              | coins: 2,
                influences: [
                  %{role: :captain, revealed: false},
                  %{role: :assassin, revealed: false}
                ]
            }
          ]
      }

    view = Game.view(game, player_one.id)

    assert {:take_action, "tax", nil} = Bot.choose_move(view, game, player_one.id)
  end

  test "chooses exchange indexes from the offered exchange options" do
    {:ok, game} =
      Game.new([
        %{id: "player-one", name: "Player 1"},
        %{id: "player-two", name: "Player 2"}
      ])

    [player_one, player_two] = game.players

    game = %{
      game
      | active_player_id: player_one.id,
        players: [
          %{
            player_one
            | influences: [
                %{role: :ambassador, revealed: true},
                %{role: :contessa, revealed: false}
              ]
          },
          player_two
        ],
        phase: %{
          kind: :awaiting_exchange,
          player_id: player_one.id,
          keep_count: 1,
          options: [:contessa, :captain, :duke],
          deck_rest: [:assassin]
        }
    }

    view = Game.view(game, player_one.id)

    assert {:exchange, [2]} = Bot.choose_move(view, game, player_one.id)
    assert {:ok, _game} = Game.choose_exchange(game, player_one.id, [2])
  end
end
