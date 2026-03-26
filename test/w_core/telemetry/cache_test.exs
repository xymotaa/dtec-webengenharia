defmodule WCore.Telemetry.CacheTest do
  use ExUnit.Case, async: true

  alias WCore.Telemetry.Cache

  # Gera IDs únicos para isolar cada teste na tabela ETS global
  defp uid, do: System.unique_integer([:positive])

  describe "upsert/4" do
    test "insere nova entrada com event_count=1 na primeira chamada" do
      id = uid()
      Cache.upsert(id, "ok", ~s({"temp":72}), DateTime.utc_now())

      entry = Cache.get(id)
      assert entry.status == "ok"
      assert entry.event_count == 1
      assert entry.last_payload == ~s({"temp":72})
    end

    test "incrementa o contador atomicamente em chamadas subsequentes" do
      id = uid()
      ts = DateTime.utc_now()

      Cache.upsert(id, "ok", "{}", ts)
      Cache.upsert(id, "ok", "{}", ts)
      Cache.upsert(id, "ok", "{}", ts)

      assert Cache.get(id).event_count == 3
    end

    test "atualiza o status sem resetar o contador" do
      id = uid()
      ts = DateTime.utc_now()

      Cache.upsert(id, "ok", "{}", ts)
      Cache.upsert(id, "ok", "{}", ts)
      Cache.upsert(id, "critical", "{}", ts)

      entry = Cache.get(id)
      assert entry.event_count == 3
      assert entry.status == "critical"
    end

    test "atualiza last_payload a cada evento" do
      id = uid()
      ts = DateTime.utc_now()

      Cache.upsert(id, "ok", ~s({"seq":1}), ts)
      Cache.upsert(id, "ok", ~s({"seq":2}), ts)

      assert Cache.get(id).last_payload == ~s({"seq":2})
    end
  end

  describe "get/1" do
    test "retorna nil para nó inexistente" do
      assert Cache.get(uid()) == nil
    end

    test "retorna mapa com todas as chaves esperadas" do
      id = uid()
      Cache.upsert(id, "warning", "{}", DateTime.utc_now())

      entry = Cache.get(id)
      assert Map.has_key?(entry, :node_id)
      assert Map.has_key?(entry, :status)
      assert Map.has_key?(entry, :event_count)
      assert Map.has_key?(entry, :last_payload)
      assert Map.has_key?(entry, :last_seen_at)
    end
  end

  describe "all/0" do
    test "inclui os nós inseridos neste teste" do
      ids = for _ <- 1..3, do: uid()
      Enum.each(ids, &Cache.upsert(&1, "ok", "{}", DateTime.utc_now()))

      cached_ids = Cache.all() |> Enum.map(& &1.node_id)
      assert Enum.all?(ids, &(&1 in cached_ids))
    end
  end

  describe "update_counter — integridade atômica" do
    test "100 upserts sequenciais resultam em event_count exato" do
      id = uid()
      ts = DateTime.utc_now()

      for _ <- 1..100, do: Cache.upsert(id, "ok", "{}", ts)

      assert Cache.get(id).event_count == 100
    end
  end
end
