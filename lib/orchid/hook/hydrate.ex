defmodule Orchid.Runner.Hooks.Hydrate do
  @behaviour Orchid.Runner.Hook

  def call(ctx, next_fn) do
    next_fn.(ctx)
  end
end
