defmodule QyCore.Step.Wrapper do
  @moduledoc """
  Wrap `QyCore.Step` into `Orchid.Step`(both support
  function implementation and module implementation).
  """
  def as_func(qy_core_step, input, instruments, opts) do
    qy_core_step.(input, instruments, opts)
  end

  # def as_module(qy_core_step, input, instruments, opts) do
  # end

  # defp build_module
end
