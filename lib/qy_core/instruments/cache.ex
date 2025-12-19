defmodule QyCore.Instruments.Cache do
  @moduledoc """
  Pure ETS-based cache instrument with no external service.

  Use for:
  - Storing intermediate results between steps
  - Sharing data between instruments without serialization
  - Temporary working storage during recipe execution

  ## Configuration

      {QyCore.Instruments.Cache, [
        name: :cache,
        ttl: :infinity,           # or milliseconds
        max_entries: :infinity,   # or integer
        eviction: :none           # :lru | :fifo | :none
      ]}

  ## Examples

      # Basic usage
      {:ok, ref} = Cache.store(%{data: "large payload"})
      {:ok, value} = Cache.fetch(ref)

      # With key
      {:ok, ref} = Cache.put("my-key", %{data: "value"})
      {:ok, value} = Cache.get("my-key")
  """

  use QyCore.Instrument

  # ============================================
  # Init
  # ============================================

  @impl QyCore.Instrument
  def handle_init(config) do
    {:ok, state} = super(config)

    handle = %{
      ttl: Keyword.get(config, :ttl, :infinity),
      max_entries: Keyword.get(config, :max_entries, :infinity),
      eviction: Keyword.get(config, :eviction, :none),
      index_table: nil,
      # Monotonic counter for LRU ordering
      access_counter: 0
    }

    # Create LRU index table if needed
    handle =
      if handle.eviction == :lru do
        index_name = :"#{state.meta.name}_lru_index"
        index_table = :ets.new(index_name, [:ordered_set, :protected])
        %{handle | index_table: index_table}
      else
        handle
      end

    {:ok, %{state | handle: handle}}
  end

  # ============================================
  # Run commands
  # ============================================

  @impl QyCore.Instrument
  def handle_run({:get, key}, _opts, state) do
    case do_fetch(key, state) do
      {:ok, value, state} -> {:ok, value, state}
      {:error, :not_found, state} -> {:ok, nil, state}
    end
  end

  def handle_run({:put, key, value}, _opts, state) do
    {:ok, ref, state} = do_store(key, value, state)
    {:ok, ref, state}
  end

  def handle_run({:delete, key}, _opts, state) do
    case handle_delete(key, state) do
      {:ok, state} -> {:ok, :deleted, state}
      {:error, :not_found, state} -> {:ok, :not_found, state}
    end
  end

  def handle_run({:exists?, key}, _opts, %{table: table} = state) do
    exists = :ets.member(table, key)
    {:ok, exists, state}
  end

  def handle_run(:keys, _opts, %{table: table} = state) do
    keys = :ets.foldl(fn {key, _, _, _}, acc -> [key | acc] end, [], table)
    {:ok, keys, state}
  end

  def handle_run(:size, _opts, %{table: table} = state) do
    {:ok, :ets.info(table, :size), state}
  end

  def handle_run(:clear, _opts, %{table: table, handle: handle} = state) do
    :ets.delete_all_objects(table)
    if handle.index_table, do: :ets.delete_all_objects(handle.index_table)
    new_handle = %{handle | access_counter: 0}
    {:ok, :cleared, %{state | handle: new_handle}}
  end

  def handle_run(request, _opts, state) do
    {:error, {:unknown_command, request}, state}
  end

  # ============================================
  # Override store/fetch with TTL and eviction
  # ============================================

  @impl QyCore.Instrument
  def handle_store(key, value, state) do
    do_store(key, value, state)
  end

  @impl QyCore.Instrument
  def handle_fetch(key, state) do
    do_fetch(key, state)
  end

  @impl QyCore.Instrument
  def handle_delete(key, %{table: table, handle: handle} = state) do
    case :ets.lookup(table, key) do
      [{^key, _, _, access_id}] ->
        if handle.index_table, do: :ets.delete(handle.index_table, access_id)
        :ets.delete(table, key)
        {:ok, state}

      [] ->
        {:error, :not_found, state}
    end
  end

  # ============================================
  # Cleanup
  # ============================================

  @impl QyCore.Instrument
  def handle_cleanup(_reason, %{handle: handle}) do
    if handle.index_table do
      :ets.delete(handle.index_table)
    end

    :ok
  end

  # ============================================
  # Client convenience functions
  # ============================================

  @doc "Get a value by key (returns nil if not found)"
  def get(key, opts \\ []) do
    case run({:get, key}, opts) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Put a value with explicit key"
  def put(key, value, opts \\ []) do
    run({:put, key, value}, opts)
  end

  @doc "Check if key exists"
  def exists?(key, opts \\ []) do
    case run({:exists?, key}, opts) do
      {:ok, result} -> result
      _ -> false
    end
  end

  @doc "Get all keys"
  def keys(opts \\ []) do
    run(:keys, opts)
  end

  @doc "Get entry count"
  def size(opts \\ []) do
    run(:size, opts)
  end

  @doc "Clear all entries"
  def clear(opts \\ []) do
    run(:clear, opts)
  end

  # ============================================
  # Private implementation
  # ============================================

  # Table entry format: {key, value, timestamp, access_id}
  # Index entry format: {access_id, key}

  defp do_store(key, value, %{table: table, handle: handle, meta: meta} = state) do
    now = System.system_time(:millisecond)

    # Check if this is an update (key exists) or insert (new key)
    is_update = :ets.member(table, key)

    # Only evict if at capacity AND this is a new key (not an update)
    state = if is_update, do: state, else: maybe_evict(state)

    # Get next access counter
    access_id = handle.access_counter + 1
    new_handle = %{handle | access_counter: access_id}

    # Remove old LRU entry if key exists
    if new_handle.index_table do
      remove_from_lru_index(key, table, new_handle.index_table)
    end

    # Store value with timestamp and access_id
    :ets.insert(table, {key, value, now, access_id})

    # Add new LRU index entry
    if new_handle.index_table do
      :ets.insert(new_handle.index_table, {access_id, key})
    end

    ref = {:ref, meta.name, key}
    {:ok, ref, %{state | handle: new_handle}}
  end

  defp do_fetch(key, %{table: table, handle: handle} = state) do
    case :ets.lookup(table, key) do
      [{^key, value, stored_at, _old_access_id}] ->
        if expired?(stored_at, handle.ttl) do
          # Delete expired entry
          handle_delete(key, state)
          {:error, :not_found, state}
        else
          # Update access time for LRU
          if handle.index_table do
            # Re-store to update access_id
            {:ok, _ref, new_state} = do_store(key, value, state)
            {:ok, value, new_state}
          else
            {:ok, value, state}
          end
        end

      [] ->
        {:error, :not_found, state}
    end
  end

  defp expired?(_stored_at, :infinity), do: false
  defp expired?(stored_at, ttl), do: System.system_time(:millisecond) - stored_at > ttl

  defp remove_from_lru_index(key, main_table, index_table) do
    case :ets.lookup(main_table, key) do
      [{^key, _, _, old_access_id}] ->
        :ets.delete(index_table, old_access_id)

      [] ->
        :ok
    end
  end

  defp maybe_evict(%{handle: %{max_entries: :infinity}} = state), do: state

  defp maybe_evict(%{table: table, handle: handle} = state) do
    current_size = :ets.info(table, :size)

    if current_size >= handle.max_entries do
      do_evict(state)
    else
      state
    end
  end

  defp do_evict(%{handle: %{eviction: :none}} = state), do: state

  defp do_evict(%{table: table, handle: %{eviction: :lru, index_table: index_table}} = state) do
    case :ets.first(index_table) do
      :"$end_of_table" ->
        state

      oldest_access_id ->
        [{^oldest_access_id, key}] = :ets.lookup(index_table, oldest_access_id)
        :ets.delete(index_table, oldest_access_id)
        :ets.delete(table, key)
        state
    end
  end

  defp do_evict(%{table: table, handle: %{eviction: :fifo}} = state) do
    case find_oldest(table) do
      nil ->
        state

      {key, _ts} ->
        :ets.delete(table, key)
        state
    end
  end

  defp find_oldest(table) do
    :ets.foldl(
      fn
        {key, _value, ts, _access_id}, nil -> {key, ts}
        {key, _value, ts, _access_id}, {_old_key, old_ts} when ts < old_ts -> {key, ts}
        _, acc -> acc
      end,
      nil,
      table
    )
  end
end
