defmodule Coupex.BotTest do
  use ExUnit.Case, async: true

  alias Coupex.Bot
  alias Coupex.Game

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
end
