defmodule QyCore.Orchid.Executor.GenStage do
  @moduledoc """
  A simple GenStage-based executor.
  """
  @behaviour Orchid.Executor

  alias QyCore.Orchid.Executor.GenStage.{Dispatcher, Worker}

  @impl true
  def execute(ctx, opts) do
    {:ok, producer_pid} = Dispatcher.start_link(ctx, self())

    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())

    for id <- 1..concurrency do
      Worker.start_link(producer_pid, id)
    end

    receive do
      {:recipe_done, {:ok, results}} ->
        {:ok, results}

      {:recipe_done, {:error, reason}} ->
        {:error, reason}

    after
      30_000 -> {:error, :timeout}
    end
  end
end
