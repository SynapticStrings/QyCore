defmodule Orchid.Runner.Hooks.MaybeInjectInstruments do
  @moduledoc """
  Hook that injects Instrument modules into QyCore.Step execution.

  Transforms 3-arity QyCore steps into 2-arity Orchid-compatible functions,
  separating QyCore/Orchid/business options.

  ## Usage

      Orchid.run(recipe, input, hooks: [Orchid.Runner.Hooks.MaybeInjectInstruments])
  """

  @behaviour Orchid.Runner.Hook

  @impl Orchid.Runner.Hook
  def call(ctx, next) do
    impl = ctx.step_implementation

    if QyCore.Step.qycore_step?(impl) do
      inject_and_execute(ctx, impl, next)
    else
      next.(ctx)
    end
  end

  defp inject_and_execute(ctx, impl, next) do
    # Build instrument map
    inst_map = build_instrument_map(impl.instruments())

    # Separate options
    full_opts = ctx.opts || []
    {qycore_opts, rest} = Keyword.pop(full_opts, :qycore, [])
    {orchid_opts, business_opts} = Keyword.pop(rest, :orchid, [])

    # Set context on instruments for key generation
    recipe_id = get_in(ctx.assigns, [:recipe_id]) || "anonymous"
    step_name = ctx.step_name

    Enum.each(inst_map, fn {_name, module} ->
      module.set_context(recipe_id, step_name)
    end)

    # Wrap implementation
    wrapped = fn input, _orchid_opts ->
      impl.run(input, inst_map, business_opts)
    end

    # Store QyCore context in assigns
    qycore_context = %{
      opts: qycore_opts,
      instruments: impl.instruments(),
      inst_map: inst_map
    }

    new_assigns = Map.put(ctx.assigns || %{}, :qycore, qycore_context)

    # Execute with orchid opts
    ctx = %{ctx | step_implementation: wrapped, opts: orchid_opts, assigns: new_assigns}
    result = next.(ctx)

    # Clear context after execution
    Enum.each(inst_map, fn {_name, module} ->
      module.clear_context()
    end)

    result
  end

  defp build_instrument_map(names) do
    Map.new(names, fn name ->
      module = QyCore.InstrumentsRegistry.fetch!(name)
      {name, module}
    end)
  end
end
