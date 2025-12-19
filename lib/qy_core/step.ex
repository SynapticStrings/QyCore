defmodule QyCore.Step do
  @moduledoc """
  ...
  """

  @callback instruments() :: [QyCore.Instrument.name()]

  @callback run(Orchid.Step.input(), instruments :: map(), opts :: keyword()) ::
              {:ok, Orchid.Step.output()} | {:error, term()}
end
