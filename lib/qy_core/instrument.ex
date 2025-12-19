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

  # ============================================
  # __using__ macro
  # ============================================

  defmacro __using__(opts) do
    quote location: :keep do
      @behaviour QyCore.Instrument
      use GenServer

      @instrument_opts unquote(opts)

      # ----------------------------------------
      # Child spec
      # ----------------------------------------
      def child_spec(config) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [config]},
          type: :worker,
          restart: Keyword.get(@instrument_opts, :restart, :permanent)
        }
      end

      # ----------------------------------------
      # Client API
      # ----------------------------------------
      def start_link(config) do
        name = Keyword.get(config, :name, __MODULE__)
        GenServer.start_link(__MODULE__, config, name: name)
      end

      def run(request, opts \\ []) do
        name = Keyword.get(opts, :instrument, __MODULE__)
        timeout = Keyword.get(opts, :timeout, 30_000)
        GenServer.call(name, {:run, request, opts}, timeout)
      end

      def store(value, opts \\ []) do
        name = Keyword.get(opts, :instrument, __MODULE__)
        GenServer.call(name, {:store, value, opts})
      end

      def fetch(ref_or_key) do
        {name, key} = parse_ref(ref_or_key)
        GenServer.call(name, {:fetch, key})
      end

      def delete(ref_or_key) do
        {name, key} = parse_ref(ref_or_key)
        GenServer.call(name, {:delete, key})
      end

      def persist(path) do
        GenServer.call(__MODULE__, {:persist, path})
      end

      def restore(path) do
        GenServer.call(__MODULE__, {:restore, path})
      end

      def set_context(recipe_id, step_name) do
        GenServer.cast(__MODULE__, {:set_context, recipe_id, step_name})
      end

      def clear_context do
        GenServer.cast(__MODULE__, :clear_context)
      end

      defp parse_ref({:ref, name, key}), do: {name, key}
      defp parse_ref(key) when is_binary(key), do: {__MODULE__, key}

      # ----------------------------------------
      # GenServer callbacks
      # ----------------------------------------
      @impl GenServer
      def init(config) do
        case Keyword.get(config, :restore_from) do
          nil ->
            handle_init(config)

          path ->
            with {:ok, state} <- handle_init(config),
                 {:ok, state} <- handle_restore(path, state) do
              {:ok, state}
            end
        end
      end

      @impl GenServer
      def handle_call({:run, request, opts}, _from, state) do
        case handle_run(request, opts, state) do
          {:ok, response, new_state} ->
            {:reply, {:ok, response}, new_state}

          {:error, reason, new_state} ->
            {:reply, {:error, reason}, new_state}
        end
      end

      def handle_call({:store, value, opts}, _from, state) do
        key = generate_key(state.meta, opts)
        {:ok, ref, new_state} = handle_store(key, value, state)
        {:reply, {:ok, ref}, new_state}
      end

      def handle_call({:fetch, key}, _from, state) do
        case handle_fetch(key, state) do
          {:ok, value, new_state} -> {:reply, {:ok, value}, new_state}
          {:error, :not_found, new_state} -> {:reply, {:error, :not_found}, new_state}
        end
      end

      def handle_call({:delete, key}, _from, state) do
        case handle_delete(key, state) do
          {:ok, new_state} -> {:reply, :ok, new_state}
          {:error, :not_found, new_state} -> {:reply, {:error, :not_found}, new_state}
        end
      end

      def handle_call({:persist, path}, _from, state) do
        case handle_persist(path, state) do
          {:ok, new_state} -> {:reply, :ok, new_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
      end

      def handle_call({:restore, path}, _from, state) do
        case handle_restore(path, state) do
          {:ok, new_state} -> {:reply, :ok, new_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
      end

      @impl GenServer
      def handle_cast({:set_context, recipe_id, step_name}, state) do
        new_meta = %{state.meta | recipe_id: recipe_id, step_name: step_name}
        {:noreply, %{state | meta: new_meta}}
      end

      def handle_cast(:clear_context, state) do
        new_meta = %{state.meta | recipe_id: nil, step_name: nil, key_counter: 0}
        {:noreply, %{state | meta: new_meta}}
      end

      @impl GenServer
      def terminate(reason, state) do
        handle_cleanup(reason, state)
      end

      # ----------------------------------------
      # Default implementations
      # ----------------------------------------
      def handle_init(config) do
        name = Keyword.get(config, :name, __MODULE__)
        table = :ets.new(name, [:set, :protected, read_concurrency: true])

        state = %{
          table: table,
          handle: nil,
          config: config,
          meta: %{
            name: name,
            key_counter: 0,
            recipe_id: nil,
            step_name: nil
          }
        }

        {:ok, state}
      end

      def handle_run(_request, _opts, state) do
        {:error, :not_implemented, state}
      end

      def handle_store(key, value, %{table: table, meta: meta} = state) do
        :ets.insert(table, {key, value, now()})
        ref = {:ref, meta.name, key}
        {:ok, ref, state}
      end

      def handle_fetch(key, %{table: table} = state) do
        case :ets.lookup(table, key) do
          [{^key, value, _ts}] -> {:ok, value, state}
          [] -> {:error, :not_found, state}
        end
      end

      def handle_delete(key, %{table: table} = state) do
        case :ets.lookup(table, key) do
          [{^key, _, _}] ->
            :ets.delete(table, key)
            {:ok, state}

          [] ->
            {:error, :not_found, state}
        end
      end

      def handle_persist(path, %{table: table} = state) do
        path
        |> to_charlist()
        |> :ets.tab2file(extended_info: [:md5sum])
        |> case do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end
      end

      def handle_restore(path, %{table: old_table} = state) do
        # Delete old table if exists
        if old_table, do: :ets.delete(old_table)

        path
        |> to_charlist()
        |> :ets.file2tab(verify: true)
        |> case do
          {:ok, table} -> {:ok, %{state | table: table}}
          {:error, reason} -> {:error, reason}
        end
      end

      def handle_cleanup(_reason, _state), do: :ok

      # ----------------------------------------
      # Key generation
      # ----------------------------------------
      defp generate_key(%{recipe_id: nil} = meta, _opts) do
        # No context: use timestamp + counter
        counter = System.unique_integer([:positive, :monotonic])
        "#{meta.name}/#{counter}"
      end

      defp generate_key(meta, opts) do
        # With context: recipe_id/step_name/counter
        suffix = Keyword.get(opts, :suffix, System.unique_integer([:positive, :monotonic]))
        "#{meta.recipe_id}/#{meta.step_name}/#{suffix}"
      end

      defp now, do: System.system_time(:millisecond)

      # ----------------------------------------
      # Overridable
      # ----------------------------------------
      defoverridable [
        child_spec: 1,
        handle_init: 1,
        handle_run: 3,
        handle_store: 3,
        handle_fetch: 2,
        handle_delete: 2,
        handle_persist: 2,
        handle_restore: 2,
        handle_cleanup: 2
      ]
    end
  end
end
