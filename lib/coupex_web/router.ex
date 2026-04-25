defmodule CoupexWeb.Router do
  use CoupexWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug CoupexWeb.Plugs.EnsurePlayerId
    plug :fetch_live_flash
    plug :put_root_layout, html: {CoupexWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :health do
    plug :accepts, ["json"]
  end

  scope "/health", CoupexWeb do
    pipe_through :health

    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
  end

  scope "/", CoupexWeb do
    pipe_through :browser

    live_session :public do
      live "/", HomeLive, :index
      live "/rooms/:code", RoomLive, :show
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", CoupexWeb do
  #   pipe_through :api
  # end
end
