defmodule QyCoreTest do
  use ExUnit.Case
  doctest QyCore

  test "greets the world" do
    assert QyCore.hello() == :world
  end
end
