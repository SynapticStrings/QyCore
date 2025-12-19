defmodule Orchid.Executor.GenStage.Worker do
    use GenStage

    def start_link(producer_pid, id) do
      GenStage.start_link(__MODULE__, {producer_pid, id})
    end

    @impl true
    def init({producer_pid, id}) do
      {:consumer, %{producer: producer_pid, id: id}, subscribe_to: [{producer_pid, max_demand: 1}]}
    end

    @impl true
    def handle_events(events, _from, state) do
      Enum.each(events, fn {step, idx, params, opts} ->
        result = Orchid.Runner.run(step, params, opts)

        GenStage.cast(state.producer, {:step_finished, idx, result})
      end)

      {:noreply, [], state}
    end
  end
