defmodule QyCore.Instrument do
    @moduledoc """
  Behaviour for Instrument servers.

  An Instrument is a supervised GenServer that:
  1. Manages a service handle (HTTP client, NIF, Axon model, etc.)
  2. Owns local ETS storage for large params
  3. Executes computation where the data lives
  4. Supports persist/restore for checkpoint & resume

  ## Usage

      defmodule MyApp.Instruments.Embedder do
        use QyCore.Instrument

        def handle_init(config) do
          # Custom initialization
          {:ok, state} = super(config)
          model = load_model(config[:model_path])
          {:ok, %{state | handle: model}}
        end

        def handle_run(request, opts, state) do
          result = compute_embedding(state.handle, request)
          {:ok, result, state}
        end
      end

  ## Distributed

  Instruments can be called remotely via `{name, node}` addressing:

      QyCore.Instrument.run({:embedder, :"worker@host"}, request)
  """

  @type name :: atom()
  @type config :: keyword()
  @type state :: %{
          table: :ets.tid(),
          handle: term(),
          config: config(),
          meta: meta()
        }
  @type meta :: %{
          name: name(),
          key_counter: pos_integer(),
          recipe_id: String.t() | nil,
          step_name: atom() | nil
        }
  @type ref :: {:ref, name(), key :: String.t()}

  # ============================================
  # Callbacks (implement these)
  # ============================================

  @doc "Initialize instrument state. Called on start."
  @callback handle_init(config()) :: {:ok, state()} | {:error, term()}

  @doc "Execute computation. Runs inside Instrument process."
  @callback handle_run(request :: term(), opts :: keyword(), state()) ::
              {:ok, response :: term(), state()}
              | {:error, reason :: term(), state()}

  @doc "Store a value. Default uses ETS."
  @callback handle_store(key :: String.t(), value :: term(), state()) ::
              {:ok, ref(), state()}

  @doc "Fetch a value by key. Default uses ETS."
  @callback handle_fetch(key :: String.t(), state()) ::
              {:ok, value :: term(), state()}
              | {:error, :not_found, state()}

  @doc "Delete a value by key. Default uses ETS."
  @callback handle_delete(key :: String.t(), state()) ::
              {:ok, state()}
              | {:error, :not_found, state()}

  @doc "Persist ETS to disk."
  @callback handle_persist(path :: Path.t(), state()) ::
              {:ok, state()} | {:error, term()}

  @doc "Restore ETS from disk."
  @callback handle_restore(path :: Path.t(), state()) ::
              {:ok, state()} | {:error, term()}

  @doc "Cleanup on termination. Override for custom cleanup."
  @callback handle_cleanup(reason :: term(), state()) :: :ok

  # ============================================
  # Client API (auto-generated)
  # ============================================

  @doc "Start the Instrument under a supervisor"
  @callback start_link(config()) :: GenServer.on_start()

  @doc "Execute a computation"
  @callback run(request :: term(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc "Store a value, receive a ref"
  @callback store(value :: term(), opts :: keyword()) ::
              {:ok, ref()} | {:error, term()}

  @doc "Fetch a value by ref or key"
  @callback fetch(ref() | String.t()) ::
              {:ok, term()} | {:error, :not_found}

  @doc "Delete a value by ref or key"
  @callback delete(ref() | String.t()) ::
              :ok | {:error, :not_found}

  @doc "Persist to disk"
  @callback persist(path :: Path.t()) :: :ok | {:error, term()}

  @doc "Restore from disk"
  @callback restore(path :: Path.t()) :: :ok | {:error, term()}

  @doc "Set context for key generation"
  @callback set_context(recipe_id :: String.t(), step_name :: atom()) :: :ok

  @doc "Clear context"
  @callback clear_context() :: :ok
end
