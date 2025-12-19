defmodule QyCore.Instruments.NxServing.Supervisor do
  @moduledoc """
  Supervisor for a single NxServing instrument + its Nx.Serving process.

  Use this when you want the Instrument and Serving to be supervised together.

  ## Usage

      # In your application.ex
      children = [
        {QyCore.Instruments.NxServing.Supervisor, [
          name: :embedder,
          serving_fn: &MyApp.Models.build_embedder/1,
          serving_opts: [model: "bge-m3"],
          batch_timeout: 50
        ]}
      ]

  This starts:
  1. The Nx.Serving process (`:embedder_serving`)
  2. The QyCore.Instruments.NxServing GenServer (`:embedder`)

  If either crashes, both are restarted (`:rest_for_one` strategy).
  """

  use Supervisor

  def start_link(config) do
    name = Keyword.fetch!(config, :name)
    Supervisor.start_link(__MODULE__, config, name: :"#{name}_sup")
  end

  @impl true
  def init(config) do
    name = Keyword.fetch!(config, :name)
    serving_name = Keyword.get(config, :serving_name, :"#{name}_serving")
    batch_timeout = Keyword.get(config, :batch_timeout, 100)

    # Build serving
    serving = build_serving(config)

    children = [
      # Nx.Serving process (must start first)
      {Nx.Serving,
       serving: serving,
       name: serving_name,
       batch_timeout: batch_timeout},

      # QyCore Instrument (depends on serving)
      {QyCore.Instruments.NxServing,
       Keyword.merge(config,
         serving_name: serving_name,
         # Don't pass serving directly - it's already started above
         serving: nil
       )}
    ]

    # :rest_for_one - if serving crashes, instrument restarts too
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp build_serving(config) do
    case Keyword.get(config, :serving) do
      nil ->
        serving_fn = Keyword.fetch!(config, :serving_fn)
        serving_opts = Keyword.get(config, :serving_opts, [])
        serving_fn.(serving_opts)

      serving ->
        serving
    end
  end
end
