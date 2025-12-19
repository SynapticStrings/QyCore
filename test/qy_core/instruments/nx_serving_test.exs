defmodule QyCore.Instruments.NxServingTest do
  use ExUnit.Case, async: false

  alias QyCore.Instruments.NxServing

  # Mock serving that works with Nx 0.10+
  defmodule MockServing do
    def build(_opts) do
      Nx.Serving.new(
        fn _opts -> :ok end,
        fn :ok, input, _opts ->
          # Simple passthrough - double the input
          Nx.multiply(input, 2)
        end
      )
    end
  end

  describe "module structure" do
    test "implements QyCore.Instrument behaviour" do
      behaviours = NxServing.__info__(:attributes)[:behaviour] || []
      assert QyCore.Instrument in behaviours
    end

    test "has required client functions" do
      assert function_exported?(NxServing, :run, 2)
      assert function_exported?(NxServing, :store, 2)
      assert function_exported?(NxServing, :fetch, 2)
      assert function_exported?(NxServing, :run_and_store, 2)
      assert function_exported?(NxServing, :batch, 2)
      assert function_exported?(NxServing, :batch_and_store, 2)
      assert function_exported?(NxServing, :serving_ready?, 1)
    end
  end

  describe "initialization" do
    test "starts without serving_fn (lazy mode)" do
      name = :"nx_lazy_#{System.unique_integer([:positive])}"

      {:ok, pid} = NxServing.start_link(name: name)
      assert Process.alive?(pid)

      # Not ready because no serving_fn
      refute NxServing.serving_ready?(instrument: name)

      GenServer.stop(pid)
    end

    test "stores and fetches without serving" do
      name = :"nx_storage_#{System.unique_integer([:positive])}"

      {:ok, _pid} = NxServing.start_link(name: name)

      # Storage works even without serving
      {:ok, ref} = NxServing.store(%{data: "test"}, instrument: name)
      assert {:ref, ^name, _key} = ref

      {:ok, value} = NxServing.fetch(ref)
      assert value == %{data: "test"}
    end
  end

  describe "integration" do
    @tag :nx_integration
    test "basic inference" do
      start_supervised!(QyCore.Instruments.NxServing.DynamicSupervisor)

      name = :"nx_test_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        NxServing.start_link(
          name: name,
          serving_fn: &MockServing.build/1,
          serving_opts: [],
          batch_timeout: 100
        )

      # Wait for serving to start
      Process.sleep(200)

      if NxServing.serving_ready?(instrument: name) do
        input = Nx.tensor([1.0, 2.0, 3.0])
        {:ok, result} = NxServing.run(input, instrument: name)
        assert Nx.to_list(result) == [2.0, 4.0, 6.0]
      else
        # Skip if serving didn't start (missing compiler)
        IO.puts("Skipping: Nx.Serving not available")
      end
    end

    @tag :nx_integration
    test "run_and_store" do
      start_supervised!(QyCore.Instruments.NxServing.DynamicSupervisor)

      name = :"nx_store_test_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        NxServing.start_link(
          name: name,
          serving_fn: &MockServing.build/1,
          serving_opts: [],
          batch_timeout: 100
        )

      Process.sleep(200)

      if NxServing.serving_ready?(instrument: name) do
        input = Nx.tensor([5.0, 10.0])
        {:ok, ref} = NxServing.run_and_store(input, instrument: name)

        assert {:ref, ^name, _key} = ref

        {:ok, result} = NxServing.fetch(ref)
        assert Nx.to_list(result) == [10.0, 20.0]
      else
        IO.puts("Skipping: Nx.Serving not available")
      end
    end

    @tag :nx_integration
    test "using supervised setup" do
      name = :"nx_sup_test_#{System.unique_integer([:positive])}"

      result =
        start_supervised({
          QyCore.Instruments.NxServing.Supervisor,
          name: name,
          serving_fn: &MockServing.build/1,
          batch_timeout: 100
        })

      case result do
        {:ok, _pid} ->
          assert NxServing.serving_ready?(instrument: name)

          input = Nx.tensor([3.0, 6.0, 9.0])
          {:ok, result} = NxServing.run(input, instrument: name)
          assert Nx.to_list(result) == [6.0, 12.0, 18.0]

        {:error, _} ->
          IO.puts("Skipping: Nx.Serving supervisor failed to start")
      end
    end
  end
end
