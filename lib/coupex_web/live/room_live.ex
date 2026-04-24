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
         |> assign(:exchange_selection, [])
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
        {:noreply, socket |> assign(:snapshot, snapshot) |> assign(:lobby_error, nil)}

      {:error, message} ->
        {:noreply, socket |> put_flash(:error, message) |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("toggle_ready", _, socket),
    do: room_action(socket, fn s -> RoomServer.toggle_ready(s.code, s.viewer_id) end)

  def handle_event("start_game", _, socket),
    do: room_action(socket, fn s -> RoomServer.start_game(s.code, s.viewer_id) end)

  def handle_event("pass", _, socket),
    do: room_action(socket, fn s -> RoomServer.pass(s.code, s.viewer_id) end)

  def handle_event("challenge", _, socket),
    do: room_action(socket, fn s -> RoomServer.challenge(s.code, s.viewer_id) end)

  def handle_event("block", %{"role" => role}, socket) do
    room_action(socket, fn s -> RoomServer.block(s.code, s.viewer_id, role) end)
  end

  def handle_event("take_action", params, socket) do
    action = params["action"]
    target_id = blank_to_nil(params["target"])

    room_action(socket, fn s -> RoomServer.take_action(s.code, s.viewer_id, action, target_id) end)
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
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="court-shell">
        <div class="court-topbar">
          <div class="brand-block">
            <.link navigate={~p"/"} class="brand-link">
              <span class="brand-mark"></span>
              <span>Coup</span>
              <span class="brand-sub">The Parlor</span>
            </.link>
          </div>

          <div :if={@snapshot.game} class="court-stats">
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

        <%= if @snapshot.game do %>
          <div class="court-app">
            <section class="table-panel">
              <div class="lobby-strip">
                <%= for player <- @snapshot.lobby_players do %>
                  <div class={["lobby-chip", player.host && "host"]}>
                    <span>{player.name}</span>
                    <span :if={player.host}>Host</span>
                  </div>
                <% end %>
              </div>

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

                <div class={seat_grid_class(length(@snapshot.game.players))}>
                  <%= for player <- @snapshot.game.players do %>
                    <article class={[
                      "seat-card",
                      player.you && "seat-you",
                      player.id == @snapshot.game.active_player_id && "seat-active",
                      player.eliminated && "seat-out"
                    ]}>
                      <div class="seat-head">
                        <div>
                          <p class="seat-name">{player.name}</p>
                          <p class="seat-meta">
                            {player.coins} coin{if player.coins != 1, do: "s"} · {player.alive_count} influence
                          </p>
                        </div>
                        <div class="seat-avatar">{String.first(player.name)}</div>
                      </div>

                      <div class="seat-cards">
                        <%= for influence <- player.influences do %>
                          <div class={[
                            "influence-card",
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
                <div class="dock-summary">
                  <p>Your hand</p>
                  <strong>{@snapshot.game.you.name}</strong>
                </div>

                <div class="dock-hand">
                  <%= for {influence, index} <- Enum.with_index(@snapshot.game.you.influences) do %>
                    <button
                      type="button"
                      id={"your-influence-#{index}"}
                      class={["hand-card", influence.revealed && "revealed"]}
                      phx-click="reveal"
                      phx-value-index={index}
                      disabled={
                        @snapshot.game.interaction.kind != :reveal or
                          not @snapshot.game.interaction.your_turn or influence.revealed
                      }
                    >
                      <span>{influence.role || "Hidden"}</span>
                    </button>
                  <% end %>
                </div>

                <div
                  :if={
                    @snapshot.game.interaction.kind == :action and
                      @snapshot.game.interaction.your_turn
                  }
                  class="dock-actions"
                >
                  <%= for action <- @snapshot.game.you.available_actions do %>
                    <%= if action.target do %>
                      <form
                        id={"action-form-#{action.id}"}
                        class="targeted-action-form"
                        phx-submit="take_action"
                      >
                        <input type="hidden" name="action" value={action.id} />
                        <label>
                          <span>{action.label}</span>
                          <select name="target" class="court-select">
                            <option value="">Target</option>
                            <%= for target <- action.targets do %>
                              <option value={target.id}>{target.name}</option>
                            <% end %>
                          </select>
                        </label>
                        <button type="submit" class="court-button small">Play</button>
                      </form>
                    <% else %>
                      <button
                        type="button"
                        class="court-button small"
                        phx-click="take_action"
                        phx-value-action={action.id}
                        phx-value-target=""
                      >
                        {action.label}
                      </button>
                    <% end %>
                  <% end %>
                </div>

                <div :if={@snapshot.game.interaction.kind == :respond_action} class="response-card">
                  <p>
                    {@snapshot.game.interaction.pending.actor_name} claims {@snapshot.game.interaction.pending.claim_role}
                  </p>
                  <div class="response-actions">
                    <button
                      :if={@snapshot.game.interaction.can_challenge}
                      type="button"
                      class="court-button small"
                      phx-click="challenge"
                    >
                      Challenge
                    </button>
                    <button
                      :if={@snapshot.game.interaction.can_pass}
                      type="button"
                      class="court-button small"
                      phx-click="pass"
                    >
                      Allow
                    </button>
                  </div>
                </div>

                <div :if={@snapshot.game.interaction.kind == :block} class="response-card">
                  <p>Block {@snapshot.game.interaction.pending.action_label}?</p>
                  <div class="response-actions">
                    <button
                      :for={{role, index} <- Enum.with_index(@snapshot.game.interaction.block_roles)}
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

                <div class="turn-banner">
                  <span>Turn {@snapshot.game.turn_number}</span>
                  <strong>{@snapshot.game.active_player_name}</strong>
                  <span>
                    <%= if @snapshot.game.status == :finished do %>
                      court concluded
                    <% else %>
                      in the spotlight
                    <% end %>
                  </span>
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

              <div class="chronicle-list" id="chronicle-list">
                <%= for entry <- @snapshot.game.log do %>
                  <div class={["log-entry", Atom.to_string(entry.kind)]}>
                    {render_log(entry)}
                  </div>
                <% end %>
              </div>
            </aside>
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
      </div>
    </Layouts.app>
    """
  end

  defp room_action(socket, fun, after_success \\ & &1) do
    state = %{code: socket.assigns.snapshot.code, viewer_id: socket.assigns.viewer_id}

    case fun.(state) do
      {:ok, snapshot} ->
        {:noreply,
         socket
         |> assign(:snapshot, snapshot)
         |> assign(:lobby_error, nil)
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

  defp seat_grid_class(count), do: "seat-grid seat-grid-#{count}"

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
