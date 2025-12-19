defmodule QyCore.Instrument do
  @moduledoc """
  Behaviour and GenServer foundation for QyCore Instruments.

  An Instrument is a supervised GenServer that:
  1. Manages a service handle (HTTP client, NIF, Nx.Serving, etc.)
  2. Owns local ETS storage for large params
  3. Executes computation where the data lives
  4. Supports persist/restore for checkpoint & resume

  ## Usage

      defmodule MyApp.Instruments.Embedder do
        use QyCore.Instrument

        @impl true
        def handle_init(config) do
          {:ok, state} = super(config)
          model = load_model(config[:model_path])
          {:ok, %{state | handle: model}}
        end

        @impl true
        def handle_run(request, opts, state) do
          result = compute_embedding(state.handle, request)
          {:ok, result, state}
        end
      end

  ## Distributed

  Instruments can be called remotely via `{name, node}` addressing:

      MyInstrument.run(request, instrument: {:embedder, :"worker@host"})
  """

  # ============================================
  # Types
  # ============================================

  @type name :: atom()
  @type config :: keyword()
  @type key :: String.t()
  @type ref :: {:ref, name(), key()}

  @type meta :: %{
          name: name(),
          key_counter: non_neg_integer(),
          recipe_id: String.t() | nil,
          step_name: atom() | nil
        }

  @type state :: %{
          table: :ets.tid() | nil,
          handle: term(),
          config: config(),
          meta: meta()
        }

  # ============================================
  # Callbacks
  # ============================================

  @doc "Initialize instrument state. Called on start."
  @callback handle_init(config()) :: {:ok, state()} | {:error, term()}

  @doc "Execute computation. Runs inside Instrument process."
  @callback handle_run(request :: term(), opts :: keyword(), state()) ::
              {:ok, response :: term(), state()}
              | {:error, reason :: term(), state()}

  @doc "Store a value. Default uses ETS."
  @callback handle_store(key(), value :: term(), state()) ::
              {:ok, ref(), state()}

  @doc "Fetch a value by key. Default uses ETS."
  @callback handle_fetch(key(), state()) ::
              {:ok, value :: term(), state()}
              | {:error, :not_found, state()}

  @doc "Delete a value by key. Default uses ETS."
  @callback handle_delete(key(), state()) ::
              {:ok, state()}
              | {:error, :not_found, state()}

  @doc "Persist ETS to disk."
  @callback handle_persist(path :: Path.t(), state()) ::
              {:ok, state()} | {:error, term()}

  @doc "Restore ETS from disk."
  @callback handle_restore(path :: Path.t(), state()) ::
              {:ok, state()} | {:error, term()}

  @doc "Cleanup on termination."
  @callback handle_cleanup(reason :: term(), state()) :: :ok

  # ============================================
  # __using__ macro
  # ============================================

  defmacro __using__(opts \\ []) do
    quote location: :keep do
      @behaviour QyCore.Instrument
      use GenServer

      @instrument_opts unquote(opts)

      # ----------------------------------------
      # Child spec
      # ----------------------------------------

      def child_spec(config) do
        name = Keyword.get(config, :name, __MODULE__)

        %{
          id: name,
          start: {__MODULE__, :start_link, [config]},
          type: :worker,
          restart: Keyword.get(@instrument_opts, :restart, :permanent)
        }
      end

      # ----------------------------------------
      # Client API
      # ----------------------------------------

      def start_link(config \\ []) do
        name = Keyword.get(config, :name, __MODULE__)
        GenServer.start_link(__MODULE__, config, name: name)
      end

      @doc "Execute a computation"
      def run(request, opts \\ []) do
        name = Keyword.get(opts, :instrument, __MODULE__)
        timeout = Keyword.get(opts, :timeout, 30_000)
        GenServer.call(name, {:run, request, opts}, timeout)
      end

      @doc "Store a value, receive a ref"
      def store(value, opts \\ []) do
        name = Keyword.get(opts, :instrument, __MODULE__)
        GenServer.call(name, {:store, value, opts})
      end

      @doc "Fetch a value by ref or key"
      def fetch(ref_or_key, opts \\ []) do
        {name, key} = parse_ref(ref_or_key, opts)
        GenServer.call(name, {:fetch, key})
      end

      @doc "Delete a value by ref or key"
      def delete(ref_or_key, opts \\ []) do
        {name, key} = parse_ref(ref_or_key, opts)
        GenServer.call(name, {:delete, key})
      end

      @doc "Persist to disk"
      def persist(path, opts \\ []) do
        name = Keyword.get(opts, :instrument, __MODULE__)
        GenServer.call(name, {:persist, path})
      end

      @doc "Restore from disk (call on running instrument)"
      def restore(path, opts \\ []) do
        name = Keyword.get(opts, :instrument, __MODULE__)
        GenServer.call(name, {:restore, path})
      end

      @doc "Set context for key generation (recipe_id, step_name)"
      def set_context(recipe_id, step_name, opts \\ []) do
        name = Keyword.get(opts, :instrument, __MODULE__)
        GenServer.cast(name, {:set_context, recipe_id, step_name})
      end

      @doc "Clear context"
      def clear_context(opts \\ []) do
        name = Keyword.get(opts, :instrument, __MODULE__)
        GenServer.cast(name, :clear_context)
      end

      @doc "Get current state info (for debugging)"
      def info(opts \\ []) do
        name = Keyword.get(opts, :instrument, __MODULE__)
        GenServer.call(name, :info)
      end

      defp parse_ref({:ref, ref_name, key}, _opts), do: {ref_name, key}

      defp parse_ref(key, opts) when is_binary(key) do
        name = Keyword.get(opts, :instrument, __MODULE__)
        {name, key}
      end

      # ----------------------------------------
      # GenServer callbacks
      # ----------------------------------------

      @impl GenServer
      def init(config) do
        # Check if restoring from checkpoint
        case Keyword.get(config, :restore_from) do
          nil ->
            handle_init(config)

          path ->
            with {:ok, state} <- handle_init(config),
                 {:ok, state} <- handle_restore(path, state) do
              {:ok, state}
            else
              {:error, reason} -> {:stop, reason}
            end
        end
      end

      @impl GenServer
      def handle_call({:run, request, opts}, _from, state) do
        {flag, response, new_state} = handle_run(request, opts, state)

        {:reply, {flag, response}, new_state}
      end

      def handle_call({:store, value, opts}, _from, state) do
        key = generate_key(state.meta, opts)
        {:ok, ref, new_state} = handle_store(key, value, state)
        {:reply, {:ok, ref}, new_state}
      end

      def handle_call({:fetch, key}, _from, state) do
        case handle_fetch(key, state) do
          {:ok, value, new_state} ->
            {:reply, {:ok, value}, new_state}

          {:error, :not_found, new_state} ->
            {:reply, {:error, :not_found}, new_state}
        end
      end

      def handle_call({:delete, key}, _from, state) do
        case handle_delete(key, state) do
          {:ok, new_state} ->
            {:reply, :ok, new_state}

          {:error, :not_found, new_state} ->
            {:reply, {:error, :not_found}, new_state}
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

      def handle_call(:info, _from, state) do
        info = %{
          meta: state.meta,
          config: state.config,
          table_size: table_size(state.table),
          handle_type: handle_type(state.handle)
        }

        {:reply, info, state}
      end

      defp table_size(nil), do: 0
      defp table_size(table), do: :ets.info(table, :size)

      defp handle_type(nil), do: nil
      defp handle_type(%{__struct__: mod}), do: mod
      defp handle_type(handle) when is_map(handle), do: :map
      defp handle_type(_), do: :other

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
      # Default callback implementations
      # ----------------------------------------

      @impl QyCore.Instrument
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

      @impl QyCore.Instrument
      def handle_run(_request, _opts, state) do
        {:error, :not_implemented, state}
      end

      @impl QyCore.Instrument
      def handle_store(key, value, %{table: table, meta: meta} = state) do
        timestamp = System.system_time(:millisecond)
        :ets.insert(table, {key, value, timestamp})
        ref = {:ref, meta.name, key}
        {:ok, ref, state}
      end

      @impl QyCore.Instrument
      def handle_fetch(key, %{table: table} = state) do
        case :ets.lookup(table, key) do
          [{^key, value, _timestamp}] ->
            {:ok, value, state}

          [] ->
            {:error, :not_found, state}
        end
      end

      @impl QyCore.Instrument
      def handle_delete(key, %{table: table} = state) do
        case :ets.lookup(table, key) do
          [{^key, _, _}] ->
            :ets.delete(table, key)
            {:ok, state}

          [] ->
            {:error, :not_found, state}
        end
      end

      @impl QyCore.Instrument
      def handle_persist(path, %{table: table} = state) do
        path
        |> to_charlist()
        |> then(&:ets.tab2file(table, &1, extended_info: [:md5sum]))
        |> case do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end
      end

      @impl QyCore.Instrument
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

      @impl QyCore.Instrument
      def handle_cleanup(_reason, _state), do: :ok

      # ----------------------------------------
      # Key generation
      # ----------------------------------------

      defp generate_key(%{recipe_id: nil, name: name}, _opts) do
        counter = System.unique_integer([:positive, :monotonic])
        "#{name}/#{counter}"
      end

      defp generate_key(%{recipe_id: recipe_id, step_name: step_name}, opts) do
        suffix = Keyword.get(opts, :key_suffix, System.unique_integer([:positive, :monotonic]))
        "#{recipe_id}/#{step_name}/#{suffix}"
      end

      # ----------------------------------------
      # Overridable
      # ----------------------------------------

      defoverridable child_spec: 1,
                     handle_init: 1,
                     handle_run: 3,
                     handle_store: 3,
                     handle_fetch: 2,
                     handle_delete: 2,
                     handle_persist: 2,
                     handle_restore: 2,
                     handle_cleanup: 2
    end
  end
end
