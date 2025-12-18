defmodule QyCore.OrchidHook.MaybeInjectInstruments do
  @behaviour Orchid.Runner.Hook

  def call(ctx, next) do
    impl = ctx.step_implementation

    if is_atom(impl) and function_exported?(impl, :instruments, 0) and
         function_exported?(impl, :run, 3) do
      inst_map =
        impl.instruments()
        |> Enum.map(fn name -> {name, name} end)
        |> Map.new()

      wrapped = fn input, opts -> impl.run(input, inst_map, opts) end

      next.(%{ctx | step_implementation: wrapped})
    else
      next.(ctx)
    end
  end
end
