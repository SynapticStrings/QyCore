defmodule QyCore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      QyCore.InstrumentsRegistry,
      {QyCore.Instruments.Cache,
       [
         name: :cache,
         max_entries: 10_000,
         eviction: :lru
       ]}
    ]

    opts = [strategy: :one_for_one, name: QyCore.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      register_instruments()
      {:ok, pid}
    end
  end

  defp register_instruments do
    QyCore.InstrumentsRegistry.register(:cache, QyCore.Instruments.Cache)
  end
end
