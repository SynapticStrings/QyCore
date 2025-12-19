defmodule QyCore.OrchidHook.MaybeInjectInstruments do
  @behaviour Orchid.Runner.Hook

  @impl true
  def call(ctx, next) do
    impl = ctx.step_implementation

    if qycore_step?(impl) do
      inst_map = build_instrument_map(impl.instruments())
      wrapped = fn input, opts -> impl.run(input, inst_map, opts) end
      next.(%{ctx | step_implementation: wrapped})
    else
      next.(ctx)
    end
  end

  defp qycore_step?(impl) when is_atom(impl) do
    Code.ensure_loaded?(impl) and
      function_exported?(impl, :instruments, 0) and
      function_exported?(impl, :run, 3)
  end

  defp qycore_step?(_), do: false

  defp build_instrument_map(names) do
    Map.new(names, fn name ->
      module = QyCore.InstrumentsRegistry.fetch!(name)
      {name, module}
    end)
  end
end
