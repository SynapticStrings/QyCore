defmodule QyCore.Instrument.InstrumentServer do
  alias QyCore.Instrument
  @behaviour Instrument
  use GenServer

  # ----------------------------------------
  # Child spec
  # ----------------------------------------

  def child_spec(config, opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [config]},
      type: :worker,
      restart: Keyword.get(opts, :restart, :permanent)
    }
  end

  # ----------------------------------------
  # Client API
  # ----------------------------------------

  @impl Instrument
  def start_link(config) do
    name = Keyword.get(config, :name, __MODULE__)
    GenServer.start_link(__MODULE__, config, name: name)
  end

  @impl Instrument
  def run(request, opts \\ []) do
    name = Keyword.get(opts, :instrument, __MODULE__)
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(name, {:run, request, opts}, timeout)
  end

  @impl Instrument
  def store(value, opts \\ []) do
    name = Keyword.get(opts, :instrument, __MODULE__)
    GenServer.call(name, {:store, value, opts})
  end

  @impl Instrument
  def fetch(ref_or_key) do
    {name, key} = parse_ref(ref_or_key)
    GenServer.call(name, {:fetch, key})
  end

  @impl Instrument
  def delete(ref_or_key) do
    {name, key} = parse_ref(ref_or_key)
    GenServer.call(name, {:delete, key})
  end

  @impl Instrument
  def persist(path) do
    GenServer.call(__MODULE__, {:persist, path})
  end

  @impl Instrument
  def restore(path) do
    GenServer.call(__MODULE__, {:restore, path})
  end

  @impl Instrument
  def set_context(recipe_id, step_name) do
    GenServer.cast(__MODULE__, {:set_context, recipe_id, step_name})
  end

  @impl Instrument
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
  @impl Instrument
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

  @impl Instrument
  def handle_run(_request, _opts, state) do
    {:error, :not_implemented, state}
  end

  @impl Instrument
  def handle_store(key, value, %{table: table, meta: meta} = state) do
    :ets.insert(table, {key, value, now()})
    ref = {:ref, meta.name, key}
    {:ok, ref, state}
  end

  @impl Instrument
  def handle_fetch(key, %{table: table} = state) do
    case :ets.lookup(table, key) do
      [{^key, value, _ts}] -> {:ok, value, state}
      [] -> {:error, :not_found, state}
    end
  end

  @impl Instrument
  def handle_delete(key, %{table: table} = state) do
    case :ets.lookup(table, key) do
      [{^key, _, _}] ->
        :ets.delete(table, key)
        {:ok, state}

      [] ->
        {:error, :not_found, state}
    end
  end

  @impl Instrument
  def handle_persist(path, %{table: table} = state) do
    path
    |> to_charlist()
    |> :ets.tab2file(extended_info: [:md5sum])
    |> case do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Instrument
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

  @impl Instrument
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
end
