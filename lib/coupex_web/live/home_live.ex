defmodule CoupexWeb.HomeLive do
  use CoupexWeb, :live_view

  alias Coupex.RoomServer

  @impl true
  def mount(_params, session, socket) do
    form = to_form(%{"name" => "", "room_code" => ""}, as: :entry)

    {:ok,
     socket
     |> assign(:page_title, "Enter the Court")
     |> assign(:visitor_id, session["visitor_id"])
     |> assign(:form, form)
     |> assign(:current_scope, nil)}
  end

  @impl true
  def handle_event("create_room", %{"entry" => %{"name" => name}}, socket) do
    case RoomServer.create_room(socket.assigns.visitor_id, name, self()) do
      {:ok, code} -> {:noreply, push_navigate(socket, to: ~p"/rooms/#{code}")}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("join_room", %{"entry" => %{"name" => name, "room_code" => room_code}}, socket) do
    case RoomServer.join_room(room_code, socket.assigns.visitor_id, name, self()) do
      {:ok, _snapshot} ->
        {:noreply, push_navigate(socket, to: ~p"/rooms/#{String.upcase(String.trim(room_code))}")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section class="landing-shell">
        <div class="landing-card">
          <p class="landing-tag">Bluff · Deduce · Betray</p>
          <h1 class="landing-title">Coup<span>.</span></h1>
          <p class="landing-copy">
            A parlor game of deception for two to six. Claim any role, whether you hold it or not,
            and outlast the court.
          </p>

          <.form for={@form} id="entry-form" class="landing-form">
            <div class="landing-grid">
              <div class="landing-field">
                <.input
                  field={@form[:name]}
                  type="text"
                  label="Your name, for the record"
                  placeholder="Isolde"
                  class="court-input"
                />
              </div>

              <div class="landing-button-wrap">
                <button type="submit" class="court-button court-button-dark landing-primary-button" phx-click="create_room">
                  Create Room
                </button>
              </div>
            </div>

            <div class="landing-room-row">
              <div class="landing-room-field">
                <span class="room-label">Room code</span>
                <.input
                  field={@form[:room_code]}
                  type="text"
                  placeholder="VELVET"
                  class="court-input court-input-room"
                />
              </div>

              <div class="landing-button-wrap">
                <button type="submit" class="court-button landing-secondary-button" phx-click="join_room">
                  Join Room
                </button>
              </div>
            </div>
          </.form>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
