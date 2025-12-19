defmodule QyCore.Instruments.NxServing do
  @moduledoc """
  Instrument backed by Nx.Serving for local ML models.

  Combines:
  - Nx.Serving's batching, preprocessing, model execution
  - QyCore.Instrument's ref storage, persistence, checkpoint

  ## Configuration

      # Option 1: Pre-built serving
      {QyCore.Instruments.NxServing, [
        name: :embedder,
        serving: my_serving
      ]}

      # Option 2: Lazy build (recommended for persistence/restore)
      {QyCore.Instruments.NxServing, [
        name: :embedder,
        serving_fn: &MyApp.Models.build_embedder/1,
        serving_opts: [model: "bge-m3"],
        batch_timeout: 50
      ]}

  ## Usage

      # Single inference
      {:ok, result} = NxServing.run(%{text: "hello"}, instrument: :embedder)

      # Run and store result as ref
      {:ok, ref} = NxServing.run_and_store(%{text: "hello"}, instrument: :embedder)

      # Batch inference
      {:ok, results} = NxServing.batch([%{text: "a"}, %{text: "b"}], instrument: :embedder)

  ## Notes

  - The Nx.Serving process runs separately under QyCore.Instruments.NxServing.Supervisor
  - Model weights are NOT persisted - only config to rebuild the serving
  - Use `serving_fn` for production (allows restore from checkpoint)
  """

  use QyCore.Instrument

  require Logger

  @default_batch_timeout 100

  # ============================================
  # Init
  # ============================================

  @impl QyCore.Instrument
  def handle_init(config) do
    {:ok, state} = super(config)

    serving_name = Keyword.get(config, :serving_name, :"#{state.meta.name}_serving")
    batch_timeout = Keyword.get(config, :batch_timeout, @default_batch_timeout)

    handle = %{
      serving_name: serving_name,
      serving_fn: Keyword.get(config, :serving_fn),
      serving_opts: Keyword.get(config, :serving_opts, []),
      batch_timeout: batch_timeout,
      serving_pid: nil
    }

    # If serving is provided directly, we assume it's already started externally
    # If serving_fn is provided, we'll start it ourselves
    handle =
      case Keyword.get(config, :serving) do
        nil ->
          # Lazy init - serving will be started by supervisor or on first use
          handle

        serving ->
          # Direct serving provided - start it now
          case start_serving(serving, serving_name, batch_timeout) do
            {:ok, pid} ->
              %{handle | serving_pid: pid}

            {:error, reason} ->
              Logger.warning("Failed to start serving: #{inspect(reason)}")
              handle
          end
      end

    {:ok, %{state | handle: handle}}
  end

  # ============================================
  # Run
  # ============================================

  @impl QyCore.Instrument
  def handle_run(request, opts, %{handle: handle} = state) do
    state = ensure_serving_started(state)

    timeout = Keyword.get(opts, :timeout, handle.batch_timeout * 10)

    try do
      result = Nx.Serving.batched_run(handle.serving_name, request, timeout)
      {:ok, result, state}
    rescue
      e in ArgumentError ->
        {:error, {:serving_error, :not_started, e.message}, state}

      e ->
        {:error, {:serving_error, :exception, Exception.message(e)}, state}
    catch
      :exit, reason ->
        {:error, {:serving_error, :exit, reason}, state}
    end
  end

  # ============================================
  # Persistence
  # ============================================

  # Created by Claude originally
  # but dialyzer caught warnings
  # so let return type allow `{:error, reason}`
  @impl QyCore.Instrument
  def handle_persist(path, %{handle: handle} = state) do
    # Save ETS data (refs)
    {:ok, state} = super(path, state)

    # Save serving config (NOT weights - those reload from source)
    if handle.serving_fn do
      serving_config = %{
        serving_fn: handle.serving_fn,
        serving_opts: handle.serving_opts,
        batch_timeout: handle.batch_timeout
      }

      config_path = "#{path}.serving.etf"

      case File.write(config_path, :erlang.term_to_binary(serving_config)) do
        :ok ->
          {:ok, state}

        {:error, reason} ->
          Logger.warning("Failed to persist serving config: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:ok, state}
    end
  end

  # Created by Claude originally
  # but dialyzer caught warnings
  # so let return type allow `{:error, reason}`
  @impl QyCore.Instrument
  def handle_restore(path, state) do
    # Restore ETS data
    {:ok, state} = super(path, state)

    # Restore serving config and rebuild
    config_path = "#{path}.serving.etf"

    case File.read(config_path) do
      {:ok, binary} ->
        %{serving_fn: serving_fn, serving_opts: serving_opts, batch_timeout: batch_timeout} =
          :erlang.binary_to_term(binary)

        new_handle = %{
          state.handle
          | serving_fn: serving_fn,
            serving_opts: serving_opts,
            batch_timeout: batch_timeout,
            serving_pid: nil
        }

        {:ok, %{state | handle: new_handle}}

      {:error, :enoent} ->
        # No serving config - that's OK
        {:ok, state}

      {:error, reason} ->
        Logger.warning("Failed to restore serving config: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl QyCore.Instrument
  def handle_cleanup(_reason, %{handle: handle}) do
    # Stop serving if we started it
    if handle.serving_pid && Process.alive?(handle.serving_pid) do
      # Nx.Serving doesn't have a stop function, so we just let it be
      # cleaned up by the supervisor
      :ok
    end

    :ok
  end

  # ============================================
  # Client Convenience Functions
  # ============================================

  @doc "Run inference and store result, return ref"
  def run_and_store(request, opts \\ []) do
    with {:ok, result} <- run(request, opts) do
      store(result, opts)
    end
  end

  @doc "Run batch inference"
  def batch(inputs, opts \\ []) when is_list(inputs) do
    run(inputs, opts)
  end

  @doc "Run batch inference and store each result"
  def batch_and_store(inputs, opts \\ []) when is_list(inputs) do
    with {:ok, results} <- batch(inputs, opts) do
      refs =
        results
        |> ensure_list()
        |> Enum.map(fn result ->
          {:ok, ref} = store(result, opts)
          ref
        end)

      {:ok, refs}
    end
  end

  @doc "Check if serving is running"
  def serving_ready?(opts \\ []) do
    name = Keyword.get(opts, :instrument, __MODULE__)
    GenServer.call(name, :serving_ready?)
  end

  @doc "Manually start the serving (if using lazy init)"
  def start_serving(opts \\ []) do
    name = Keyword.get(opts, :instrument, __MODULE__)
    GenServer.call(name, :start_serving, 60_000)
  end

  # ============================================
  # Additional GenServer Handlers
  # ============================================

  def handle_call(:serving_ready?, _from, %{handle: handle} = state) do
    ready = handle.serving_pid != nil && Process.alive?(handle.serving_pid)
    {:reply, ready, state}
  end

  def handle_call(:start_serving, _from, state) do
    case ensure_serving_started(state) do
      %{handle: %{serving_pid: pid}} = new_state when is_pid(pid) ->
        {:reply, {:ok, pid}, new_state}

      new_state ->
        {:reply, {:error, :failed_to_start}, new_state}
    end
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp ensure_serving_started(%{handle: %{serving_pid: pid}} = state)
       when is_pid(pid) do
    if Process.alive?(pid) do
      state
    else
      do_start_serving(state)
    end
  end

  defp ensure_serving_started(state), do: do_start_serving(state)

  defp do_start_serving(%{handle: handle} = state) do
    case handle.serving_fn do
      nil ->
        Logger.warning("No serving_fn configured, cannot start serving")
        state

      serving_fn when is_function(serving_fn, 1) ->
        Logger.info("Building serving with opts: #{inspect(handle.serving_opts)}")

        try do
          serving = serving_fn.(handle.serving_opts)

          case start_serving(serving, handle.serving_name, handle.batch_timeout) do
            {:ok, pid} ->
              Logger.info("Serving started: #{inspect(handle.serving_name)}")
              %{state | handle: %{handle | serving_pid: pid}}

            {:error, reason} ->
              Logger.error("Failed to start serving: #{inspect(reason)}")
              state
          end
        rescue
          e ->
            Logger.error("Error building serving: #{Exception.message(e)}")
            state
        end
    end
  end

  defp start_serving(serving, name, batch_timeout) do
    # Start Nx.Serving as a child - this is typically done by a supervisor
    # For standalone use, we start it directly
    child_spec = {
      Nx.Serving,
      serving: serving, name: name, batch_timeout: batch_timeout
    }

    case DynamicSupervisor.start_child(QyCore.Instruments.NxServing.DynamicSupervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_list(%Nx.Batch{} = batch), do: batch.stack
  defp ensure_list(list) when is_list(list), do: list
  defp ensure_list(tensor) when is_struct(tensor, Nx.Tensor), do: Nx.to_list(tensor)
  defp ensure_list(other), do: [other]
end
