defmodule QyCore.Instrument do
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @type name :: atom()

  @callback handle(name()) :: term()
end
