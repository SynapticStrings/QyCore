defmodule QyCore.Step do
  @moduledoc """
  Behaviour for QyCore steps that use Instruments.

  A QyCore.Step declares its instrument dependencies and receives
  them as a map in `run/3`.

  ## Options Structure

  Options are separated by concern:

      [
        # QyCore-level (handled by hooks)
        qycore: [
          timeout: 30_000,
          checkpoint: true
        ],
        # Orchid-level (passed to Orchid)
        orchid: [
          telemetry_prefix: [:my_app, :pipeline]
        ],
        # Business logic (passed to run/3)
        model: "gpt-4",
        temperature: 0.7
      ]

  ## Example

      defmodule MyApp.Steps.Enrich do
        @behaviour QyCore.Step

        @impl true
        def instruments, do: [:embedder, :cache]

        @impl true
        def run(input, inst, opts) do
          model = Keyword.get(opts, :model, "default")

          with {:ok, embedding_ref} <- inst.embedder.run_and_store(%{text: input.text}),
               {:ok, result_ref} <- inst.cache.put("result", %{embedding: embedding_ref}) do
            {:ok, %{result: result_ref}}
          end
        end
      end
  """

  @type input :: term()
  @type output :: term()
  @type instruments :: %{atom() => module()}
  @type opts :: keyword()

  @doc "List of instrument names this step requires"
  @callback instruments() :: [atom()]

  @doc "Execute the step with input, instruments map, and business options"
  @callback run(input(), instruments(), opts()) ::
              {:ok, output()} | {:error, term()}

  @optional_callbacks [instruments: 0]

  @doc "Check if a module is a QyCore.Step"
  def qycore_step?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :instruments, 0) and
      function_exported?(module, :run, 3)
  end

  def qycore_step?(_), do: false
end
