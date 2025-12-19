defmodule QyCore.InstrumentsRegistry do
  @moduledoc """
  Registry for Instrument modules.

  Maps instrument names to their modules for lookup during Step execution.
  Instruments are supervised separately — this only tracks the mapping.

  ## Usage

      # Register at app start
      QyCore.InstrumentsRegistry.register(:embedder, MyApp.Instruments.Embedder)

      # Lookup in hooks/steps
      {:ok, module} = QyCore.InstrumentsRegistry.fetch(:embedder)
  """

  use GenServer

  # ============================================
  # Client API
  # ============================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Register an instrument module under a name"
  def register(name, module, opts \\ []) do
    registry = Keyword.get(opts, :registry, __MODULE__)
    GenServer.call(registry, {:register, name, module})
  end

  @doc "Fetch an instrument module by name"
  def fetch(name, opts \\ []) do
    registry = Keyword.get(opts, :registry, __MODULE__)
    GenServer.call(registry, {:fetch, name})
  end

  @doc "Fetch or raise"
  def fetch!(name, opts \\ []) do
    case fetch(name, opts) do
      {:ok, module} -> module
      {:error, :not_found} -> raise ArgumentError, "Instrument #{inspect(name)} not registered"
    end
  end

  @doc "List all registered instruments"
  def list(opts \\ []) do
    registry = Keyword.get(opts, :registry, __MODULE__)
    GenServer.call(registry, :list)
  end

  @doc "Unregister an instrument"
  def unregister(name, opts \\ []) do
    registry = Keyword.get(opts, :registry, __MODULE__)
    GenServer.call(registry, {:unregister, name})
  end

  @doc "Check if an instrument is registered"
  def registered?(name, opts \\ []) do
    case fetch(name, opts) do
      {:ok, _} -> true
      {:error, :not_found} -> false
    end
  end

  # ============================================
  # GenServer callbacks
  # ============================================

  @impl GenServer
  def init(_opts) do
    {:ok, %{instruments: %{}}}
  end

  @impl GenServer
  def handle_call({:register, name, module}, _from, state) do
    new_instruments = Map.put(state.instruments, name, module)
    {:reply, :ok, %{state | instruments: new_instruments}}
  end

  def handle_call({:fetch, name}, _from, state) do
    case Map.fetch(state.instruments, name) do
      {:ok, module} -> {:reply, {:ok, module}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, state.instruments, state}
  end

  def handle_call({:unregister, name}, _from, state) do
    new_instruments = Map.delete(state.instruments, name)
    {:reply, :ok, %{state | instruments: new_instruments}}
  end
end
