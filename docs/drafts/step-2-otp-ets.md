# Step 2 — O Coração da Usina (OTP + ETS)

## O que foi implementado

- `WCore.Telemetry.Cache` — GenServer que cria e detém a tabela ETS `:w_core_telemetry_cache`
- `WCore.Telemetry.IngestServer` — GenServer que recebe eventos de sensores via `cast` e grava no ETS
- `WCore.Telemetry.WriteBehindWorker` — Worker que sincroniza o ETS com o SQLite a cada 5 segundos
- `WCore.Telemetry.Supervisor` — Supervisor com estratégia `:rest_for_one` para os três processos
- `WCore.Telemetry` (contexto público) — API do domínio, incluindo `upsert_node_metric/1`
- `WCore.Application` atualizado para iniciar o `Telemetry.Supervisor`

## Arquitetura

```
Sensor → IngestServer.ingest(node_id, payload)
              │
              ▼ (cast assíncrono)
         IngestServer
              │
              ├─ Cache.upsert(node_id, status, payload, ts)  → ETS (RAM, instantâneo)
              │
              └─ status mudou? → PubSub.broadcast("telemetry:nodes", {:status_changed, ...})
                                        │
                                        ▼
                                   LiveView (Passo 3)

                    [a cada 5s]
         WriteBehindWorker ──→ Cache.all() ──→ Telemetry.upsert_node_metric/1 ──→ SQLite
```

### Árvore de supervisão

```
WCore.Application (Supervisor, :one_for_one)
├── WCoreWeb.Telemetry
├── WCore.Repo
├── Ecto.Migrator
├── Phoenix.PubSub
├── WCore.Telemetry.Supervisor  (:rest_for_one)
│   ├── WCore.Telemetry.Cache           [1º — cria o ETS]
│   ├── WCore.Telemetry.IngestServer    [2º — escreve no ETS]
│   └── WCore.Telemetry.WriteBehindWorker [3º — sincroniza com SQLite]
└── WCoreWeb.Endpoint
```

## Decisões Arquiteturais e Trade-offs

### Por que uma tabela ETS do tipo `:set`?

`:set` garante uma única entrada por chave (`node_id`). O estado de um sensor é sempre o **último** conhecido — não há histórico granular no ETS, apenas o snapshot atual. Isso é exatamente o que o dashboard precisa: "qual é o status da Máquina 7 agora?", não "quais foram todos os status da Máquina 7".

Alternativas descartadas:
- `:bag` / `:duplicate_bag` — permitiriam múltiplas entradas por chave; não faz sentido para um snapshot
- `:ordered_set` — ordena as chaves, overhead desnecessário; a ordem não importa aqui

### Por que `:public` e não `:protected`?

`:protected` (padrão) permitiria apenas o processo dono (Cache) escrever, e todos leem. Mas como o `IngestServer` chama `Cache.upsert/4` que invoca `:ets.insert_new` e `:ets.update_counter` **diretamente** (sem passar pelo processo Cache), a tabela precisa ser `:public`. O benefício é que escritas não passam por message passing — são operações atômicas direto na RAM.

**Importante**: como o `IngestServer` é o único escritor (serializado por ser um GenServer), não há condição de corrida nas operações compostas (`insert_new` + `update_element`).

### Por que `update_counter` para o `event_count`?

`ets:update_counter/3` é uma operação **atômica** nativa do Erlang. Garante que o contador nunca perde uma incrementação, mesmo sob carga. Alternativa seria fazer `lookup` + `insert` (read-modify-write), que cria uma janela de inconsistência em cenários multi-escritor.

### Por que `cast` e não `call` no IngestServer?

`GenServer.call` é síncrono — o sensor (ou o processo chamador) fica bloqueado aguardando confirmação. `GenServer.cast` é assíncrono (fire-and-forget). Para um sistema que absorve milhares de pulsos por segundo, bloquear o chamador seria um gargalo inaceitável. A ETS não retorna erro silenciosamente — qualquer exceção derruba o GenServer e o Supervisor o reinicia.

### Por que `:rest_for_one` e não `:one_for_one` no Telemetry.Supervisor?

Os filhos têm **dependência de ordem**:

| Filho | Depende de |
|---|---|
| Cache | Nada (cria o ETS) |
| IngestServer | ETS criado pelo Cache |
| WriteBehindWorker | ETS criado pelo Cache |

Com `:one_for_one`, se o `Cache` crashar e reiniciar, o `IngestServer` continuaria tentando usar uma tabela ETS que não existe mais (o nome é recriado mas o pid é diferente, e a tabela foi destruída). Com `:rest_for_one`, todos os processos após o Cache na lista são reiniciados junto com ele.

### O padrão Write-Behind e a durabilidade

O DCREADME exige: *"o histórico deve estar a salvo caso o servidor reinicie"*.

**Garantia oferecida:** o SQLite contém o último estado sincronizado (até 5 segundos atrás). Em caso de crash, perdemos no máximo os eventos do intervalo de sincronização — aceitável para este contexto. O que **nunca** se perde é o histórico consolidado.

**Trade-off:** Se precisássemos de zero perda de dados, usaríamos WAL (Write-Ahead Log) ou um log de eventos persistido. Mas isso aumentaria a latência de escrita — contrário ao objetivo do sistema.

### Por que o Telemetry.Supervisor inicia antes do Endpoint?

Os sensores podem começar a enviar eventos assim que o servidor inicializa. Se o Endpoint subisse antes do `IngestServer`, eventos poderiam chegar via HTTP sem ter onde aterrissar. Iniciando o supervisor de telemetria antes, garantimos que a fila (GenServer) está pronta para receber.
