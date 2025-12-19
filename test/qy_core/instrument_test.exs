defmodule QyCore.InstrumentTest do
  use ExUnit.Case, async: true

  defmodule TestInstrument do
    use QyCore.Instrument

    @impl true
    def handle_init(config) do
      {:ok, state} = super(config)
      handle = %{multiplier: Keyword.get(config, :multiplier, 2)}
      {:ok, %{state | handle: handle}}
    end

    @impl true
    def handle_run(%{value: value}, _opts, %{handle: handle} = state) do
      result = value * handle.multiplier
      {:ok, result, state}
    end
  end

  setup do
    name = :"test_instrument_#{System.unique_integer([:positive])}"
    {:ok, pid} = TestInstrument.start_link(name: name, multiplier: 3)
    %{name: name, pid: pid}
  end

  describe "basic operations" do
    test "run/2 executes computation", %{name: name} do
      assert {:ok, 15} = TestInstrument.run(%{value: 5}, instrument: name)
    end

    test "store/2 and fetch/1", %{name: name} do
      {:ok, ref} = TestInstrument.store(%{data: "test"}, instrument: name)
      assert {:ref, ^name, _key} = ref
      assert {:ok, %{data: "test"}} = TestInstrument.fetch(ref)
    end

    test "delete/1 removes entry", %{name: name} do
      {:ok, ref} = TestInstrument.store(%{data: "test"}, instrument: name)
      assert :ok = TestInstrument.delete(ref)
      assert {:error, :not_found} = TestInstrument.fetch(ref)
    end

    test "info/1 returns state info", %{name: name} do
      TestInstrument.store("value1", instrument: name)
      TestInstrument.store("value2", instrument: name)

      info = TestInstrument.info(instrument: name)
      assert info.table_size == 2
      assert info.meta.name == name
      assert info.handle_type == :map
    end
  end

  describe "context" do
    test "set_context affects key generation", %{name: name} do
      TestInstrument.set_context("recipe-123", :step_a, instrument: name)
      {:ok, ref} = TestInstrument.store("value", instrument: name)
      {:ref, ^name, key} = ref

      assert key =~ "recipe-123/step_a/"

      TestInstrument.clear_context(instrument: name)
    end
  end

  describe "persistence" do
    test "persist and restore", %{name: name} do
      # Store some data
      {:ok, ref1} = TestInstrument.store(%{a: 1}, instrument: name)
      {:ok, ref2} = TestInstrument.store(%{b: 2}, instrument: name)

      # Persist
      path = Path.join(System.tmp_dir!(), "test_instrument_#{name}.ets")
      assert :ok = TestInstrument.persist(path, instrument: name)

      # Start new instrument and restore
      new_name = :"restored_#{name}"
      {:ok, _pid} = TestInstrument.start_link(name: new_name, restore_from: path)

      # Verify data is restored (refs point to old name, fetch by key)
      {:ref, ^name, key1} = ref1
      {:ref, ^name, key2} = ref2

      assert {:ok, %{a: 1}} = TestInstrument.fetch(key1, instrument: new_name)
      assert {:ok, %{b: 2}} = TestInstrument.fetch(key2, instrument: new_name)

      # Cleanup
      File.rm(path)
    end
  end
end
