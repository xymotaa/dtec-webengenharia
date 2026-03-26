# Step 4 — Simulação de Caos (Testes Rigorosos)

## O que foi implementado

- `test/w_core/telemetry/cache_test.exs` — Testes unitários do módulo ETS (`Cache`)
- `test/w_core/telemetry_chaos_test.exs` — Teste de integração com 10.000 eventos concorrentes
- `IngestServer.sync/0` adicionado para sincronização determinística em testes (aceita timeout opcional)

## Estrutura dos Testes

### Testes Unitários — `CacheTest`

Cobrem o módulo `Cache` em isolamento (sem DB, sem GenServer):

| Teste | O que prova |
|---|---|
| Inserção inicial com `event_count=1` | `insert_new/2` funciona corretamente |
| Incremento atômico em chamadas subsequentes | `update_counter/3` é correto |
| Atualização de status sem resetar contador | `update_element/3` não afeta o contador |
| Atualização de `last_payload` | Os outros campos são sobrescritos |
| `get/1` retorna nil para ID inexistente | Sem efeito colateral de leitura |
| 100 upserts sequenciais → `event_count == 100` | Integridade do contador |

### Teste de Caos — `TelemetryChaosTest`

```
[Teste]
  │
  ├── Cria nó no SQLite (ID único por execução)
  │
  ├── Task.async_stream (max_concurrency = schedulers × 4)
  │      └── 10.000 tasks em paralelo → IngestServer.ingest (cast assíncrono)
  │
  ├── IngestServer.sync() ← call síncrono drena a fila de casts
  │
  ├── Assertiva 1: Cache.get(node_id).event_count == 10_000
  ├── Assertiva 2: entry.status in ~w(ok warning)  (sem valor inválido)
  │
  ├── WriteBehindWorker.sync_now() ← força flush imediato para o SQLite
  │
  ├── Assertiva 3: metric.total_events_processed == 10_000
  └── Assertiva 4: metric.status == entry.status  (ETS ↔ SQLite consistentes)
```

## Decisões Técnicas

### Por que `IngestServer.sync/0` em vez de `Process.sleep`?

`Process.sleep` é não determinístico — em máquinas lentas ou sob carga, pode não ser suficiente. `sync/1` usa `GenServer.call`, que entra na mailbox **depois** de todos os casts anteriores e só retorna quando o GenServer o processa. É a garantia formal de que a fila foi drenada.

### Por que `async: false` no teste de caos?

O `DataCase` configura o sandbox do Ecto com `shared: not tags[:async]`. Com `async: false`, o sandbox fica em modo **shared** — qualquer processo (incluindo o `WriteBehindWorker`) pode usar a conexão de banco do teste sem travamento. Com `async: true`, o sandbox ficaria em modo **checkout**, e o `WriteBehindWorker` não conseguiria acessar o banco sem um `allow` explícito.

Além disso, o teste de caos usa recursos de CPU intensamente. Rodá-lo em paralelo com outros testes poderia causar flakiness por contenção.

### Como provamos a ausência de condição de corrida?

A própria assertiva `event_count == 10_000` é a prova. Se houvesse race condition entre `insert_new` e `update_element` (ex: dois processos lendo "0 entradas" e ambos tentando fazer `insert_new`), um dos incrementos seria perdido e o contador ficaria abaixo de 10.000.

Isso não acontece porque o **`IngestServer` é o único escritor** — todos os eventos passam pela mailbox serializada do GenServer. A atomicidade do `update_counter` garante que não há perda mesmo que leitores (LiveView) acessem o ETS simultaneamente.

### Por que `Task.async_stream` e não `Enum.each` com `Task.async`?

`Task.async_stream` é a forma idiomática em Elixir para paralelismo controlado com `max_concurrency`. Ele:
1. Limita o número de tarefas concorrentes para não explodir a BEAM
2. Propaga erros (se uma tarefa falhar, o stream falha — detectamos isso no teste)
3. Aguarda a conclusão de todas as tarefas antes de continuar

Usar `max_concurrency: System.schedulers_online() * 4` garante saturação real dos schedulers sem criar contention excessiva.

### O que o teste NÃO prova (limitações honestas)

- **Durabilidade após crash real:** o teste não mata o servidor forçosamente. Para isso seria necessário um teste de nível de sistema (ex: Dockerized kill + restart).
- **Contenção em múltiplos nós:** o teste injeta todos os eventos em um único nó. Com N nós enviando eventos simultaneamente, o único gargalo seria a mailbox do `IngestServer` — para isso, a evolução seria um pool de workers por nó (Registry + DynamicSupervisor), tema documentado como melhoria futura.
