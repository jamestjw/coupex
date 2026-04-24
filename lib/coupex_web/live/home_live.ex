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
     |> assign(:form_error, nil)
     |> assign(:current_scope, nil)}
  end

  @impl true
  def handle_event(
        "submit_entry",
        %{"entry" => %{"name" => name, "room_code" => room_code}, "intent" => intent},
        socket
      ) do
    with :ok <- validate_name(name) do
      case intent do
        "create" ->
          case RoomServer.create_room(socket.assigns.visitor_id, name, self()) do
            {:ok, code} ->
              {:noreply,
               push_navigate(socket, to: ~p"/rooms/#{code}?name=#{normalized_name(name)}")}

            {:error, message} -> {:noreply, assign(socket, :form_error, message)}
          end

        "join" ->
          with :ok <- validate_room_code(room_code),
               {:ok, _snapshot} <-
                 RoomServer.join_room(room_code, socket.assigns.visitor_id, name, self()) do
            {:noreply,
             push_navigate(
               socket,
               to: ~p"/rooms/#{String.upcase(String.trim(room_code))}?name=#{normalized_name(name)}"
             )}
          else
            {:error, message} -> {:noreply, assign(socket, :form_error, message)}
          end

        _ ->
          {:noreply, assign(socket, :form_error, "Choose a valid action.")}
      end
    else
      {:error, message} -> {:noreply, assign(socket, :form_error, message)}
    end
  end

  defp validate_name(name) do
    if String.trim(to_string(name)) == "" do
      {:error, "Enter your name before creating or joining a room."}
    else
      :ok
    end
  end

  defp validate_room_code(room_code) do
    if String.trim(to_string(room_code)) == "" do
      {:error, "Enter a room code before joining a room."}
    else
      :ok
    end
  end

  defp normalized_name(name), do: name |> to_string() |> String.trim()

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

          <div :if={@form_error} class="landing-error" id="landing-error" role="alert">
            {@form_error}
          </div>

          <.form for={@form} id="entry-form" class="landing-form" phx-submit="submit_entry">
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
                <button type="submit" name="intent" value="create" class="court-button court-button-dark landing-primary-button">
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
                <button type="submit" name="intent" value="join" class="court-button landing-secondary-button">
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
