defmodule QyCore.Instruments.NxServing.DynamicSupervisor do
  @moduledoc """
  DynamicSupervisor for Nx.Serving processes.

  Manages serving processes started by NxServing instruments.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
