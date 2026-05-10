defmodule Coupex.Game.Phase do
  @moduledoc false

  alias Coupex.Game.Player
  alias Coupex.Game.Validation

  @type t :: %{
          required(:kind) => atom(),
          optional(atom()) => any()
        }

  @callback interaction(game :: Coupex.Game.t(), viewer_id :: String.t()) :: map()
  @callback awaiting(game :: Coupex.Game.t()) :: map()

  @callback handle_action(
              game :: Coupex.Game.t(),
              player_id :: String.t(),
              action_id :: String.t(),
              target_id :: String.t() | nil
            ) :: {:ok, Coupex.Game.t()} | {:error, String.t()}

  @callback handle_pass(game :: Coupex.Game.t(), player_id :: String.t()) ::
              {:ok, Coupex.Game.t()} | {:error, String.t()}

  @callback handle_challenge(game :: Coupex.Game.t(), player_id :: String.t()) ::
              {:ok, Coupex.Game.t()} | {:error, String.t()}

  @callback handle_block(game :: Coupex.Game.t(), player_id :: String.t(), role :: atom()) ::
              {:ok, Coupex.Game.t()} | {:error, String.t()}

  @callback handle_reveal(game :: Coupex.Game.t(), player_id :: String.t(), index :: integer()) ::
              {:ok, Coupex.Game.t()} | {:error, String.t()}

  @callback handle_exchange(
              game :: Coupex.Game.t(),
              player_id :: String.t(),
              indexes :: [integer()]
            ) ::
              {:ok, Coupex.Game.t()} | {:error, String.t()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Coupex.Game.Phase

      def interaction(_game, _viewer_id), do: %{kind: :none}

      def awaiting(_game),
        do: %{kind: :none, actor_ids: [], required?: false, actions: [], subject: nil}

      def handle_action(_game, _player_id, _action_id, _target_id),
        do: {:error, "That action is not available right now."}

      def handle_pass(_game, _player_id),
        do: {:error, "That action is not available right now."}

      def handle_challenge(_game, _player_id),
        do: {:error, "That action is not available right now."}

      def handle_block(_game, _player_id, _role),
        do: {:error, "That action is not available right now."}

      def handle_reveal(_game, _player_id, _index),
        do: {:error, "That action is not available right now."}

      def handle_exchange(_game, _player_id, _indexes),
        do: {:error, "That action is not available right now."}

      defoverridable interaction: 2,
                     awaiting: 1,
                     handle_action: 4,
                     handle_pass: 2,
                     handle_challenge: 2,
                     handle_block: 3,
                     handle_reveal: 3,
                     handle_exchange: 3
    end
  end

  def module(%{kind: :awaiting_action}), do: Coupex.Game.Phase.AwaitingAction
  def module(%{kind: :awaiting_action_responses}), do: Coupex.Game.Phase.AwaitingActionResponses
  def module(%{kind: :awaiting_block}), do: Coupex.Game.Phase.AwaitingBlock
  def module(%{kind: :awaiting_block_challenge}), do: Coupex.Game.Phase.AwaitingBlockChallenge
  def module(%{kind: :awaiting_reveal}), do: Coupex.Game.Phase.AwaitingReveal
  def module(%{kind: :awaiting_exchange}), do: Coupex.Game.Phase.AwaitingExchange
  def module(%{kind: :game_over}), do: Coupex.Game.Phase.GameOver

  # Helper functions previously in Phase module
  def block_candidates(game, actor_id, "foreign_aid", _target_id),
    do: alive_other_player_ids(game, actor_id)

  def block_candidates(game, _actor_id, action, target_id)
      when action in ["assassinate", "steal"] do
    if Enum.any?(game.players, &(&1.id == target_id and not Player.eliminated?(&1))) do
      [target_id]
    else
      []
    end
  end

  def block_candidates(_game, _actor_id, _action, _target_id), do: []

  def block_roles(action), do: Validation.block_roles(action)

  defp alive_other_player_ids(game, player_id) do
    game.players
    |> Enum.reject(&(&1.id == player_id or Player.eliminated?(&1)))
    |> Enum.map(& &1.id)
  end
end
