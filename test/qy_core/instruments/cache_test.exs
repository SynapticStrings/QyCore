defmodule QyCore.Instruments.CacheTest do
  use ExUnit.Case, async: true

  alias QyCore.Instruments.Cache

  setup do
    name = :"cache_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Cache.start_link(name: name)
    %{name: name}
  end

  describe "basic operations" do
    test "put and get", %{name: name} do
      assert {:ok, _ref} = Cache.put("key1", "value1", instrument: name)
      assert {:ok, "value1"} = Cache.get("key1", instrument: name)
    end

    test "store and fetch", %{name: name} do
      assert {:ok, ref} = Cache.store(%{data: "test"}, instrument: name)
      assert {:ok, %{data: "test"}} = Cache.fetch(ref)
    end

    test "exists?", %{name: name} do
      refute Cache.exists?("key1", instrument: name)
      Cache.put("key1", "value1", instrument: name)
      assert Cache.exists?("key1", instrument: name)
    end

    test "keys", %{name: name} do
      Cache.put("a", 1, instrument: name)
      Cache.put("b", 2, instrument: name)

      {:ok, keys} = Cache.keys(instrument: name)
      assert Enum.sort(keys) == ["a", "b"]
    end

    test "size", %{name: name} do
      assert {:ok, 0} = Cache.size(instrument: name)
      Cache.put("a", 1, instrument: name)
      Cache.put("b", 2, instrument: name)
      assert {:ok, 2} = Cache.size(instrument: name)
    end

    test "clear", %{name: name} do
      Cache.put("a", 1, instrument: name)
      Cache.put("b", 2, instrument: name)

      assert {:ok, :cleared} = Cache.clear(instrument: name)
      assert {:ok, 0} = Cache.size(instrument: name)
    end

    test "delete", %{name: name} do
      Cache.put("key1", "value1", instrument: name)
      assert :ok = Cache.delete("key1", instrument: name)
      assert {:ok, nil} = Cache.get("key1", instrument: name)
    end
  end

  describe "TTL" do
    test "expired entries return nil", %{name: _name} do
      # Start cache with 50ms TTL
      ttl_name = :"ttl_cache_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Cache.start_link(name: ttl_name, ttl: 50)

      Cache.put("key1", "value1", instrument: ttl_name)
      assert {:ok, "value1"} = Cache.get("key1", instrument: ttl_name)

      # Wait for expiry
      Process.sleep(60)

      assert {:ok, nil} = Cache.get("key1", instrument: ttl_name)
    end
  end

  describe "max_entries with eviction" do
    test "LRU eviction", %{name: _name} do
      lru_name = :"lru_cache_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Cache.start_link(name: lru_name, max_entries: 3, eviction: :lru)

      Cache.put("a", 1, instrument: lru_name)
      Cache.put("b", 2, instrument: lru_name)
      Cache.put("c", 3, instrument: lru_name)

      # Access "a" to make it recently used
      Cache.get("a", instrument: lru_name)

      # Add "d" - should evict "b" (least recently used)
      Cache.put("d", 4, instrument: lru_name)

      assert {:ok, 1} = Cache.get("a", instrument: lru_name)
      assert {:ok, nil} = Cache.get("b", instrument: lru_name)  # evicted
      assert {:ok, 3} = Cache.get("c", instrument: lru_name)
      assert {:ok, 4} = Cache.get("d", instrument: lru_name)
    end

    test "FIFO eviction", %{name: _name} do
      fifo_name = :"fifo_cache_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Cache.start_link(name: fifo_name, max_entries: 3, eviction: :fifo)

      Cache.put("a", 1, instrument: fifo_name)
      Process.sleep(1)  # Ensure different timestamps
      Cache.put("b", 2, instrument: fifo_name)
      Process.sleep(1)
      Cache.put("c", 3, instrument: fifo_name)

      # Add "d" - should evict "a" (oldest)
      Cache.put("d", 4, instrument: fifo_name)

      assert {:ok, nil} = Cache.get("a", instrument: fifo_name)  # evicted
      assert {:ok, 2} = Cache.get("b", instrument: fifo_name)
      assert {:ok, 3} = Cache.get("c", instrument: fifo_name)
      assert {:ok, 4} = Cache.get("d", instrument: fifo_name)
    end
  end
end
