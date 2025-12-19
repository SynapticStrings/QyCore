defmodule QyCore.Instrument do
  @moduledoc """
  Exteral resources that has its lifecycle.

  Managed by OTP.
  """

  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @type name :: atom()

  @callback handle(name()) :: term()
end
