# Step 3 — A Sala de Controle (LiveView + Design System)

## O que foi implementado

- `WCoreWeb.DashboardLive` — LiveView da Sala de Controle, protegida por autenticação
- `WCoreWeb.TelemetryComponents` — Componentes HEEx puros (`node_card`, `status_badge`, `stat_card`)
- `WCoreWeb.SensorController` — API JSON `POST /api/nodes/:machine_identifier/pulse` para ingestão de eventos
- Rota `/dashboard` (autenticada) e `/api/nodes/:id/pulse` adicionadas ao router
- Link "Sala de Controle" na navbar para usuários autenticados

## Arquitetura

```
[Sensor / Edge Device]
        │
        ▼ POST /api/nodes/:machine_identifier/pulse
WCoreWeb.SensorController
        │
        ▼ IngestServer.ingest(node_id, payload)
WCore.Telemetry.IngestServer
        │
        ├──▶ Cache.upsert(...)  →  ETS  (memória)
        │
        └──▶ PubSub.broadcast("telemetry:nodes", {:status_changed, node_id, status})
                      │
                      ▼
             WCoreWeb.DashboardLive.handle_info/2
                      │
                      ▼ assign(:nodes, Map.put(...))
             LiveView diff → re-renderiza apenas o card alterado
                      │
                      ▼
             [Navegador do Operador] — tela pisca em tempo real
```

### Fluxo de dados no mount

```
mount/3
  ├── connected?(socket)? → subscribe("telemetry:nodes") + agendar :tick
  ├── Telemetry.list_nodes()          → banco SQLite (dados estáticos)
  ├── Cache.all()                     → ETS (estado quente)
  └── build_nodes_map()               → mescla os dois em %{node_id => %{...}}
```

## Decisões Arquiteturais e Como Evitamos Gargalos no PubSub

### 1. Broadcast seletivo — apenas em mudança de status

O `IngestServer` **não** publica um evento para cada pulso recebido. Publica apenas quando `status_changed?/2` retorna verdadeiro — ou seja, quando o status do nó muda de "ok" → "critical", por exemplo.

**Por que isso importa?** Com 1.000 sensores enviando 1 pulso/segundo cada, publicar todos os eventos via PubSub geraria 1.000 mensagens/segundo para cada processo LiveView conectado. Um operador com o dashboard aberto teria seu processo inundado. Ao filtrar apenas mudanças de status, o volume de broadcasts cai drasticamente — na prática, status mudam raramente.

### 2. Separação entre PubSub (reatividade) e :tick (atualização de contadores)

| Mecanismo | Frequência | Propósito |
|---|---|---|
| PubSub `{:status_changed}` | Somente em mudança | Atualização imediata do card (tela pisca) |
| `:tick` a cada 3s | Periódico fixo | Refresh do `event_count` e `last_seen_at` |

O `:tick` lê do ETS (memória) sem nenhum hit no banco. Mesmo que o servidor tenha 500 usuários com o dashboard aberto, cada processo faz sua própria leitura do ETS — que é `:public` e `:read_concurrency: true`, otimizado exatamente para este cenário.

### 3. Map vs List nos assigns

Os nós são armazenados como `%{node_id => %{...}}` em vez de lista `[%{...}]`.

Quando chega `{:status_changed, node_id, status}` do PubSub:
- **Map**: `Map.put(nodes, node_id, updated)` → O(1)
- **List**: `Enum.map(nodes, fn n -> if n.id == node_id ... end)` → O(n)

Com centenas de nós monitorados, a diferença é relevante. Além disso, o LiveView compara o assigns antigo com o novo — como apenas uma chave do map muda, o diff é mínimo e apenas aquele card é re-renderizado.

### 4. `connected?(socket)` antes de subscrever

O LiveView faz dois renders: um estático (HTML inicial, sem WebSocket) e um dinâmico (após conectar). Subscrever ao PubSub no render estático causaria vazamento de processos — a subscrição nunca seria cancelada pois o processo morreria logo em seguida. A guarda `connected?(socket)` garante que só subscrevemos quando há uma conexão WebSocket ativa.

### 5. Componentes HEEx puros — sem JS de terceiros

Os componentes (`node_card`, `status_badge`, `stat_card`) são funções Elixir que retornam HEEx. Toda a lógica visual é declarativa — classes Tailwind/DaisyUI aplicadas via pattern matching no status do nó. A animação `animate-pulse` no card "critical" é CSS puro, sem nenhum JavaScript.

## API de Ingestão

```http
POST /api/nodes/:machine_identifier/pulse
Content-Type: application/json

{
  "status": "critical",
  "temperature": 98.5,
  "vibration": 12.3
}
```

**Resposta 200:**
```json
{"ok": true, "node_id": 1}
```

O payload é armazenado como JSON serializado no `last_payload` — preserva todas as métricas enviadas pelo sensor sem schema rígido.
