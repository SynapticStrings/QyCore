defmodule QyCore.Orchid.Executor.GenStage do
  alias Orchid.Scheduler.Context
  # @callback Orchid.Executor

  # @impl true
  def execute(%Context{} = _ctx, _executor_opts \\ []) do
    {:error, "Not Implemented"}
  end
end
