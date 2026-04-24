defmodule CoupexWeb.RoomLive do
  use CoupexWeb, :live_view

  alias Coupex.RoomServer

  @impl true
  def mount(%{"code" => code} = params, session, socket) do
    viewer_id = session["visitor_id"]
    player_name = Map.get(params, "name")

    if connected?(socket), do: RoomServer.subscribe(code)

    case RoomServer.join_room(code, viewer_id, player_name, self()) do
      {:ok, snapshot} ->
        {:ok,
         socket
         |> assign(:page_title, "Room #{snapshot.code}")
         |> assign(:viewer_id, viewer_id)
         |> assign(:snapshot, snapshot)
         |> assign(:lobby_error, nil)
         |> assign(:claim_response_key, nil)
         |> assign(:exchange_selection, [])
         |> assign(:selected_action, nil)
         |> assign(:current_scope, nil)}

      {:error, message} ->
        {:ok,
         socket
         |> put_flash(:error, message)
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_info({:room_updated, code}, socket) do
    case RoomServer.snapshot(code, socket.assigns.viewer_id) do
      {:ok, snapshot} ->
        {:noreply, apply_snapshot(socket, snapshot)}

      {:error, message} ->
        {:noreply, socket |> put_flash(:error, message) |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("toggle_ready", _, socket),
    do: room_action(socket, fn s -> RoomServer.toggle_ready(s.code, s.viewer_id) end)

  def handle_event("start_game", _, socket),
    do: room_action(socket, fn s -> RoomServer.start_game(s.code, s.viewer_id) end)

  def handle_event("pass", _, socket) do
    response_key =
      if socket.assigns.snapshot.game.interaction.kind == :respond_action,
        do: claim_key(socket.assigns.snapshot.game),
        else: nil

    room_action(
      socket,
      fn s -> RoomServer.pass(s.code, s.viewer_id) end,
      fn updated_socket ->
        if response_key,
          do: assign(updated_socket, :claim_response_key, response_key),
          else: updated_socket
      end
    )
  end

  def handle_event("challenge", _, socket),
    do: room_action(socket, fn s -> RoomServer.challenge(s.code, s.viewer_id) end)

  def handle_event("block", %{"role" => role}, socket) do
    room_action(socket, fn s -> RoomServer.block(s.code, s.viewer_id, role) end)
  end

  def handle_event("take_action", params, socket) do
    action = params["action"]
    target_id = blank_to_nil(params["target"])

    room_action(
      socket,
      fn s -> RoomServer.take_action(s.code, s.viewer_id, action, target_id) end,
      fn updated_socket -> assign(updated_socket, :selected_action, nil) end
    )
  end

  def handle_event("select_action", %{"action" => action}, socket) do
    {:noreply, assign(socket, :selected_action, action)}
  end

  def handle_event("cancel_action", _, socket) do
    {:noreply, assign(socket, :selected_action, nil)}
  end

  def handle_event("reveal", %{"index" => index}, socket) do
    room_action(socket, fn s ->
      RoomServer.reveal(s.code, s.viewer_id, String.to_integer(index))
    end)
  end

  def handle_event("toggle_exchange", %{"index" => index}, socket) do
    parsed = String.to_integer(index)
    selected = socket.assigns.exchange_selection

    next_selection =
      if parsed in selected do
        List.delete(selected, parsed)
      else
        selected ++ [parsed]
      end

    {:noreply, assign(socket, :exchange_selection, next_selection)}
  end

  def handle_event("confirm_exchange", _, socket) do
    room_action(
      socket,
      fn s -> RoomServer.exchange(s.code, s.viewer_id, socket.assigns.exchange_selection) end,
      fn updated_socket -> assign(updated_socket, :exchange_selection, []) end
    )
  end

  @impl true
  def render(assigns) do
    assigns =
      if assigns.snapshot.game do
        actions = assigns.snapshot.game.you.available_actions

        order = %{
          "income" => 1,
          "foreign_aid" => 2,
          "coup" => 3,
          "tax" => 4,
          "assassinate" => 5,
          "steal" => 6,
          "exchange" => 7
        }

        sorted_actions = Enum.sort_by(actions, &Map.get(order, &1.id, 99))

        assigns
        |> assign(:opponents, Enum.reject(assigns.snapshot.game.players, & &1.you))
        |> assign(:all_actions, sorted_actions)
        |> assign(:selected_action_map, Enum.find(actions, &(&1.id == assigns.selected_action)))
      else
        assigns
      end

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <%= if @snapshot.game do %>
        <div class="court-stage-host">
          <div class="court-shell">
            <div class="court-topbar">
              <div class="brand-block">
                <.link navigate={~p"/"} class="brand-link">
                  <span class="brand-mark"></span>
                  <span>Coup</span>
                  <span class="brand-sub">The Parlor</span>
                </.link>
              </div>

              <div class="court-stats">
                <div><span>Treasury</span><strong>{@snapshot.game.treasury}</strong></div>
                <div><span>Court Deck</span><strong>{@snapshot.game.deck_count}</strong></div>
                <div><span>Round</span><strong>{@snapshot.game.round_number}</strong></div>
                <div><span>Turn</span><strong>{@snapshot.game.turn_number}</strong></div>
              </div>

              <div class="room-pill">
                <span class="live-dot"></span>
                <span>Room {@snapshot.code}</span>
              </div>
            </div>

            <div class="court-app">
              <section class="table-panel">
                <div class="table-stage">
                  <div class="table-felt"></div>
                  <div class="table-wordmark">Coup</div>

                  <div class="center-pile">
                    <div class="deck-stack">
                      <div class="card-back"></div>
                      <div class="card-back"></div>
                      <div class="card-back"></div>
                      <span>Court · {@snapshot.game.deck_count}</span>
                    </div>

                    <div class="treasury-stack">
                      <div
                        :for={coin <- 1..min(@snapshot.game.treasury, 8)}
                        class="coin"
                        style={"--coin-index: #{coin}"}
                      >
                      </div>
                      <span>Treasury · {@snapshot.game.treasury}</span>
                    </div>
                  </div>

                  <div class={seat_grid_class(length(@opponents))}>
                    <%= for player <- @opponents do %>
                      <article
                        class={[
                          "seat-card",
                          player.id == @snapshot.game.active_player_id && "seat-active",
                          player.eliminated && "seat-out",
                          @selected_action_map && not player.eliminated && "is-targetable"
                        ]}
                        phx-click={
                          if @selected_action_map && not player.eliminated, do: "take_action"
                        }
                        phx-value-action={@selected_action_map && @selected_action_map.id}
                        phx-value-target={player.id}
                      >
                        <div class="seat-avatar-wrap">
                          <div class="seat-avatar">{String.first(player.name)}</div>
                          <div class="seat-avatar-mark">{player.alive_count}</div>
                        </div>

                        <p class="seat-name">{player.name}</p>

                        <p class="seat-role-line">
                          Player · {player.alive_count} {if player.alive_count == 1,
                            do: "card",
                            else: "cards"}
                        </p>

                        <p class="seat-coin-line">
                          <span class="seat-coin-dot"></span>
                          <span>{player.coins} coin{if player.coins != 1, do: "s"}</span>
                        </p>

                        <div class="seat-cards">
                          <%= for influence <- player.influences do %>
                            <div class={[
                              "influence-card",
                              influence.role && role_class(influence.role),
                              influence.hidden && "hidden",
                              influence.revealed && "revealed"
                            ]}>
                              <%= cond do %>
                                <% influence.hidden -> %>
                                  <span>?</span>
                                <% influence.role -> %>
                                  <span>{influence.role}</span>
                                <% true -> %>
                                  <span>Hidden</span>
                              <% end %>
                            </div>
                          <% end %>
                        </div>
                      </article>
                    <% end %>
                  </div>
                </div>

                <section class="action-dock">
                  <div class="dock-left">
                    <p class="dock-player-line">{@snapshot.game.you.name} · Seat 1</p>

                    <div class="dock-hand">
                      <%= for {influence, index} <- Enum.with_index(@snapshot.game.you.influences) do %>
                        <button
                          type="button"
                          id={"your-influence-#{index}"}
                          class={[
                            "hand-card",
                            influence.role && role_class(influence.role),
                            influence.revealed && "revealed"
                          ]}
                          phx-click="reveal"
                          phx-value-index={index}
                          disabled={
                            @snapshot.game.interaction.kind != :reveal or
                              not @snapshot.game.interaction.your_turn or influence.revealed
                          }
                        >
                          <span class="hand-card-index">{role_index(influence.role)}</span>
                          <span class="hand-card-art"></span>
                          <span class="hand-card-name">{influence.role || "Hidden"}</span>
                        </button>
                      <% end %>
                    </div>

                    <p class="dock-coin-line">
                      <span class="dock-coin-icon"></span>
                      <span>
                        {@snapshot.game.you.coins} coin{if @snapshot.game.you.coins != 1, do: "s"}
                      </span>
                      <span :if={@snapshot.game.you.coins >= 10} class="dock-warning">Must Coup</span>
                    </p>
                  </div>

                  <div class="dock-center">
                    <p class="dock-status-label">{dock_status_label(@snapshot.game)}</p>

                    <div
                      :if={
                        @snapshot.game.interaction.kind == :action and
                          @snapshot.game.interaction.your_turn
                      }
                      class="dock-actions"
                    >
                      <%= if @selected_action_map do %>
                        <div class="dock-targeting-state">
                          <p class="dock-targeting-prompt">
                            Select target for <strong>{@selected_action_map.label}</strong>
                          </p>
                          <button type="button" class="court-button small" phx-click="cancel_action">
                            Cancel
                          </button>
                        </div>
                      <% else %>
                        <div
                          :if={@all_actions != []}
                          class="dock-actions-grid dock-actions-grid-2-row"
                        >
                          <%= for action <- @all_actions do %>
                            <button
                              type="button"
                              class={[
                                "court-button",
                                "small",
                                "action-button",
                                action_class(action.id)
                              ]}
                              phx-click={if action.target, do: "select_action", else: "take_action"}
                              phx-value-action={action.id}
                              phx-value-target=""
                              disabled={action.disabled}
                            >
                              <span>{action.label}</span>
                              <span class="action-tag">{action_tag(action.id)}</span>
                            </button>
                          <% end %>
                        </div>
                      <% end %>
                    </div>

                    <div
                      :if={
                        @snapshot.game.interaction.kind == :respond_action and
                          @snapshot.game.interaction.pending.actor_id != @viewer_id and
                          @claim_response_key == claim_key(@snapshot.game) and
                          @snapshot.game.interaction.awaiting_others
                      }
                      id="claim-response-waiting"
                      class="response-card claim-response-waiting"
                    >
                      <p>You allowed this claim. Waiting for the rest of the table.</p>
                    </div>

                    <div :if={@snapshot.game.interaction.kind == :block} class="response-card">
                      <p>Block {@snapshot.game.interaction.pending.action_label}?</p>
                      <div class="response-actions">
                        <button
                          :for={
                            {role, index} <- Enum.with_index(@snapshot.game.interaction.block_roles)
                          }
                          type="button"
                          class="court-button small"
                          phx-click="block"
                          phx-value-role={Enum.at(@snapshot.game.interaction.block_role_ids, index)}
                        >
                          {role}
                        </button>
                        <button
                          :if={@snapshot.game.interaction.can_pass}
                          type="button"
                          class="court-button small"
                          phx-click="pass"
                        >
                          Pass
                        </button>
                      </div>
                    </div>

                    <div :if={@snapshot.game.interaction.kind == :respond_block} class="response-card">
                      <p>
                        {@snapshot.game.interaction.block.player_name} blocks as {@snapshot.game.interaction.block.role}
                      </p>
                      <div class="response-actions">
                        <button
                          :if={@snapshot.game.interaction.can_challenge}
                          type="button"
                          class="court-button small"
                          phx-click="challenge"
                        >
                          Challenge Block
                        </button>
                        <button
                          :if={@snapshot.game.interaction.can_pass}
                          type="button"
                          class="court-button small"
                          phx-click="pass"
                        >
                          Let It Stand
                        </button>
                      </div>
                    </div>

                    <div :if={@snapshot.game.interaction.kind == :reveal} class="response-card">
                      <p>{@snapshot.game.interaction.reason}</p>
                    </div>

                    <div
                      :if={
                        @snapshot.game.interaction.kind == :exchange and
                          @snapshot.game.interaction.your_turn
                      }
                      class="exchange-card"
                    >
                      <p>Keep exactly {@snapshot.game.interaction.keep_count} cards.</p>
                      <div class="exchange-options">
                        <button
                          :for={{role, index} <- Enum.with_index(@snapshot.game.interaction.options)}
                          type="button"
                          class={["exchange-option", index in @exchange_selection && "selected"]}
                          phx-click="toggle_exchange"
                          phx-value-index={index}
                        >
                          {role}
                        </button>
                      </div>
                      <button type="button" class="court-button small" phx-click="confirm_exchange">
                        Confirm Exchange
                      </button>
                    </div>
                  </div>

                  <div class="turn-banner">
                    <span>Turn {@snapshot.game.turn_number}</span>
                    <strong>{@snapshot.game.active_player_name}</strong>
                    <span>{turn_banner_label(@snapshot.game)}</span>
                  </div>
                </section>
              </section>

              <aside class="chronicle-panel">
                <div class="chronicle-head">
                  <div>
                    <p>Chronicle</p>
                    <span>Room {@snapshot.code}</span>
                  </div>
                </div>

                <div class="chronicle-meta">
                  <span>· {length(@snapshot.game.players)} players seated ·</span>
                  <span>Round {@snapshot.game.round_number} ·</span>
                </div>

                <div class="chronicle-list" id="chronicle-list">
                  <%= for entry <- @snapshot.game.log do %>
                    <div class={["log-entry", Atom.to_string(entry.kind)]}>
                      {render_log(entry)}
                    </div>
                  <% end %>
                </div>

                <div class="chronicle-foot">
                  <span>{length(@snapshot.game.players)} seated</span>
                  <span>·</span>
                  <span>Turn {@snapshot.game.turn_number}</span>
                </div>
              </aside>
            </div>

            <div
              :if={
                @snapshot.game.interaction.kind == :respond_action and
                  @snapshot.game.interaction.pending.actor_id != @viewer_id and
                  @claim_response_key != claim_key(@snapshot.game)
              }
              id="claim-challenge-modal"
              class="drama-overlay"
            >
              <div class="drama-sheet">
                <p class="drama-eyebrow">An action is being taken</p>
                <h2 class="drama-title">
                  <span>{@snapshot.game.interaction.pending.actor_name}</span>
                  claims
                  <span class={[
                    "drama-claim-pill",
                    role_class(@snapshot.game.interaction.pending.claim_role)
                  ]}>
                    {@snapshot.game.interaction.pending.claim_role}
                  </span>
                </h2>

                <p class="drama-body">
                  to <em>{@snapshot.game.interaction.pending.action_label}</em>
                  <%= if @snapshot.game.interaction.pending.target_name do %>
                    against <strong>{@snapshot.game.interaction.pending.target_name}</strong>
                  <% end %>.
                  Do you challenge this claim?
                </p>

                <div
                  :if={
                    @snapshot.game.interaction.can_challenge or @snapshot.game.interaction.can_pass
                  }
                  class="drama-actions"
                >
                  <button
                    :if={@snapshot.game.interaction.can_challenge}
                    id="claim-challenge-button"
                    type="button"
                    class="court-button small drama-button primary"
                    phx-click="challenge"
                  >
                    Challenge
                  </button>
                  <button
                    :if={@snapshot.game.interaction.can_pass}
                    id="claim-allow-button"
                    type="button"
                    class="court-button small drama-button"
                    phx-click="pass"
                  >
                    Allow
                  </button>
                </div>

                <p
                  :if={
                    not @snapshot.game.interaction.can_challenge and
                      not @snapshot.game.interaction.can_pass
                  }
                  class="drama-waiting"
                >
                  Waiting for eligible players to respond.
                </p>
              </div>
            </div>
          </div>
        </div>
      <% else %>
        <section class="lobby-shell">
          <div class="landing-card lobby-card">
            <p class="landing-tag">Room {@snapshot.code}</p>
            <h1 class="landing-title">Court Gathering<span>.</span></h1>

            <div class="lobby-list">
              <%= for player <- @snapshot.lobby_players do %>
                <div class="lobby-row">
                  <div>
                    <strong>{player.name}</strong>
                  </div>
                  <span class="lobby-status">{lobby_status(player)}</span>
                </div>
              <% end %>
            </div>

            <div :if={@lobby_error} class="landing-error lobby-error" id="lobby-error" role="alert">
              {@lobby_error}
            </div>

            <div class="lobby-actions">
              <button type="button" class="court-button" phx-click="toggle_ready">
                {if viewer_ready?(@snapshot), do: "Mark Unready", else: "Mark Ready"}
              </button>
              <button
                type="button"
                class="court-button court-button-dark"
                phx-click="start_game"
                disabled={not @snapshot.can_start or @snapshot.host_id != @snapshot.viewer_id}
              >
                Start Game
              </button>
            </div>

            <p class="landing-note">
              Only the host can start the game once 2 to 6 players are seated.
            </p>
          </div>
        </section>
      <% end %>
    </Layouts.app>
    """
  end

  defp room_action(socket, fun, after_success \\ & &1) do
    state = %{code: socket.assigns.snapshot.code, viewer_id: socket.assigns.viewer_id}

    case fun.(state) do
      {:ok, snapshot} ->
        {:noreply,
         socket
         |> apply_snapshot(snapshot)
         |> after_success.()}

      {:error, message} ->
        if socket.assigns.snapshot.game do
          {:noreply, put_flash(socket, :error, message)}
        else
          {:noreply, assign(socket, :lobby_error, message)}
        end
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp claim_key(nil), do: nil

  defp claim_key(%{
         interaction: %{kind: :respond_action, pending: pending},
         turn_number: turn_number
       }) do
    [
      Integer.to_string(turn_number),
      pending.actor_id,
      pending.action,
      pending.target_id || "none"
    ]
    |> Enum.join(":")
  end

  defp claim_key(_game), do: nil

  defp apply_snapshot(socket, snapshot) do
    current_claim_key = claim_key(snapshot.game)

    claim_response_key =
      if socket.assigns.claim_response_key == current_claim_key,
        do: socket.assigns.claim_response_key,
        else: nil

    socket
    |> assign(:snapshot, snapshot)
    |> assign(:lobby_error, nil)
    |> assign(:claim_response_key, claim_response_key)
  end

  defp seat_grid_class(count), do: "seat-grid seat-grid-#{count}"

  defp role_class(nil), do: nil
  defp role_class(role), do: "role-#{role |> String.downcase() |> String.replace(" ", "-")}"

  defp role_index("Duke"), do: "I"
  defp role_index("Assassin"), do: "II"
  defp role_index("Captain"), do: "III"
  defp role_index("Ambassador"), do: "IV"
  defp role_index("Contessa"), do: "V"
  defp role_index(_role), do: "?"

  defp dock_status_label(game) do
    cond do
      game.status == :finished -> "Court Concluded"
      game.interaction.kind == :action and game.interaction.your_turn -> "Your Move"
      true -> "Watching"
    end
  end

  defp turn_banner_label(game) do
    cond do
      game.status == :finished -> "Court Concluded"
      game.interaction.kind == :action and game.interaction.your_turn -> "To Act"
      true -> "Is Acting"
    end
  end

  defp action_class("income"), do: "action-income"
  defp action_class("foreign_aid"), do: "action-foreign-aid"
  defp action_class("coup"), do: "action-coup"
  defp action_class("tax"), do: "action-tax"
  defp action_class("assassinate"), do: "action-assassinate"
  defp action_class("steal"), do: "action-steal"
  defp action_class("exchange"), do: "action-exchange"
  defp action_class(_action), do: nil

  defp action_tag("income"), do: "+1"
  defp action_tag("foreign_aid"), do: "+2"
  defp action_tag("coup"), do: "-7"
  defp action_tag("tax"), do: "+3"
  defp action_tag("assassinate"), do: "-3"
  defp action_tag("steal"), do: "+2"
  defp action_tag("exchange"), do: "<>"
  defp action_tag(_action), do: ""

  defp render_log(entry) do
    case entry.kind do
      :break -> entry.text
      :challenge -> "#{entry.actor} challenged #{entry.target} on #{entry.role}"
      :block -> "#{entry.actor} #{entry.detail}"
      :reveal -> "#{entry.actor} revealed #{entry.role} and #{entry.detail}"
      :win -> "#{entry.actor} #{entry.detail}"
      :exchange -> "#{entry.actor} #{entry.detail}"
      _ -> render_action_log(entry)
    end
  end

  defp render_action_log(entry) do
    parts = [entry.actor]
    parts = if entry[:role], do: parts ++ ["claimed #{entry.role}"], else: parts ++ ["played"]
    parts = if entry[:detail], do: parts ++ [entry.detail], else: parts
    parts = if entry[:target], do: parts ++ ["against #{entry.target}"], else: parts
    Enum.join(parts, " ")
  end

  defp viewer_ready?(snapshot) do
    snapshot.lobby_players
    |> Enum.find(&(&1.id == snapshot.viewer_id))
    |> then(&(&1 && &1.ready))
  end

  defp lobby_status(player) do
    []
    |> maybe_add(player.host, "Host")
    |> maybe_add(player.ready, "Ready")
    |> case do
      [] -> "Waiting"
      labels -> Enum.join(labels, " · ")
    end
  end

  defp maybe_add(labels, true, label), do: labels ++ [label]
  defp maybe_add(labels, false, _label), do: labels
end
