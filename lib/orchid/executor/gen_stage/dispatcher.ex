defmodule Orchid.Executor.GenStage.Dispatcher do
    use GenStage
    alias Orchid.Scheduler

    def start_link(initial_ctx, caller_pid) do
      GenStage.start_link(__MODULE__, {initial_ctx, caller_pid})
    end

    @impl true
    def init({ctx, caller_pid}) do
      {:producer, %{ctx: ctx, caller: caller_pid, demand: 0}}
    end

    @impl true
    def handle_demand(incoming_demand, state) do
      new_state = %{state | demand: state.demand + incoming_demand}
      dispatch_events(new_state)
    end

    @impl true
    def handle_cast({:step_finished, step_idx, result}, state) do
      case result do
        {:ok, outputs} ->
          new_ctx = Scheduler.merge_result(state.ctx, step_idx, outputs)

          if Scheduler.done?(new_ctx) do
            send(state.caller, {:recipe_done, {:ok, Scheduler.get_results(new_ctx)}})
            {:stop, :normal, state}
          else
            dispatch_events(%{state | ctx: new_ctx})
          end

        {:error, reason} ->
          send(state.caller, {:recipe_done, {:error, reason}})
          {:stop, :normal, state}
      end
    end

    defp dispatch_events(state) do
      ready_steps = Scheduler.next_ready_steps(state.ctx)

      events_to_dispatch = Enum.take(ready_steps, state.demand)
      count = length(events_to_dispatch)

      if count > 0 do
        step_indices = Enum.map(events_to_dispatch, fn {_, idx} -> idx end)
        new_ctx = Scheduler.mark_running_steps(state.ctx, step_indices)

        events =
           Enum.map(events_to_dispatch, fn {step, idx} ->
             {step, idx, new_ctx.params, new_ctx.recipe.opts}
           end)

        {:noreply, events, %{state | ctx: new_ctx, demand: state.demand - count}}
      else
        {:noreply, [], state}
      end
    end
  end
