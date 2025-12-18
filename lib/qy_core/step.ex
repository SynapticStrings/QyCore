defmodule QyCore.Step do
  @callback instruments() :: [QyCore.Instrument.name()]

  @callback run(Orchid.Step.input(), instruments :: map(), opts :: keyword()) ::
              {:ok, any()} | {:error, term()}
end
