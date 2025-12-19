defmodule QyCore.InstrumentsRegistryTest do
  use ExUnit.Case, async: true

  setup do
    name = :"registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = QyCore.InstrumentsRegistry.start_link(name: name)
    %{registry: name}
  end

  test "register and fetch", %{registry: registry} do
    assert :ok = QyCore.InstrumentsRegistry.register(:test, SomeModule, registry: registry)
    assert {:ok, SomeModule} = QyCore.InstrumentsRegistry.fetch(:test, registry: registry)
  end

  test "fetch! raises for unknown", %{registry: registry} do
    assert_raise ArgumentError, ~r/not registered/, fn ->
      QyCore.InstrumentsRegistry.fetch!(:unknown, registry: registry)
    end
  end

  test "list returns all registered", %{registry: registry} do
    QyCore.InstrumentsRegistry.register(:a, ModuleA, registry: registry)
    QyCore.InstrumentsRegistry.register(:b, ModuleB, registry: registry)

    instruments = QyCore.InstrumentsRegistry.list(registry: registry)
    assert instruments == %{a: ModuleA, b: ModuleB}
  end

  test "unregister removes entry", %{registry: registry} do
    QyCore.InstrumentsRegistry.register(:test, SomeModule, registry: registry)
    assert :ok = QyCore.InstrumentsRegistry.unregister(:test, registry: registry)
    assert {:error, :not_found} = QyCore.InstrumentsRegistry.fetch(:test, registry: registry)
  end

  test "registered? check", %{registry: registry} do
    refute QyCore.InstrumentsRegistry.registered?(:test, registry: registry)
    QyCore.InstrumentsRegistry.register(:test, SomeModule, registry: registry)
    assert QyCore.InstrumentsRegistry.registered?(:test, registry: registry)
  end
end
