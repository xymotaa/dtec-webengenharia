# Step 5 — Infraestrutura e Arquitetura de Deploy

## O que foi implementado

- `Dockerfile` — Build multi-estágio: `builder` (compila) + `runner` (executa)
- `.dockerignore` — Exclui deps, _build, bancos locais, logs e assets compilados
- `docker-compose.yml` — Orquestra o container com volume persistente para SQLite
- `rel/overlays/bin/migrate` — Script de migração executado dentro do release OTP
- `lib/w_core/release.ex` — Módulo Elixir para rodar migrações sem Mix

## Arquitetura de Deploy

```
┌──────────────────────────────────────────────────────────┐
│                         Docker Host                      │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │               Container: app (porta 4000)          │  │
│  │                                                    │  │
│  │  ┌──────────────────────────────────────────────┐  │  │
│  │  │               OTP Release (Erlang VM)        │  │  │
│  │  │                                              │  │  │
│  │  │  WCore.Application                           │  │  │
│  │  │    ├── WCore.Repo (SQLite)                   │  │  │
│  │  │    ├── WCore.Telemetry.Supervisor            │  │  │
│  │  │    │     ├── Cache (ETS owner)               │  │  │
│  │  │    │     ├── IngestServer (GenServer)        │  │  │
│  │  │    │     └── WriteBehindWorker (GenServer)   │  │  │
│  │  │    └── WCoreWeb.Endpoint (Bandit HTTP)       │  │  │
│  │  └──────────────────────────────────────────────┘  │  │
│  │                          │                         │  │
│  │                          │ SQLite writes           │  │
│  │                          ▼                         │  │
│  │  ┌────────────────────────────────────────────┐    │  │
│  │  │  Volume: /data/w_core_prod.db              │    │  │
│  │  │  (montado do volume Docker: sqlite_data)   │    │  │
│  │  └────────────────────────────────────────────┘    │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  Volume Docker: sqlite_data (persistido no host)         │
└──────────────────────────────────────────────────────────┘
```

## Build Multi-Estágio — Por que dois estágios?

### Stage 1: `builder`
- **Imagem base:** `hexpm/elixir` (~600 MB com Elixir + Erlang + ferramentas de build)
- **O que faz:**
  1. `mix deps.get --only prod` — baixa apenas as dependências de produção
  2. `mix assets.deploy` — compila Tailwind + esbuild com minificação
  3. `mix compile` — compila o código Elixir para BEAM bytecode
  4. `mix release` — empacota tudo em um OTP release autossuficiente

### Stage 2: `runner`
- **Imagem base:** `debian:bookworm-slim` (~80 MB)
- **O que contém:** apenas o Erlang runtime + libsqlite3 + o release compilado
- **O que NÃO contém:** Elixir, Mix, código-fonte, dependências de dev/test
- **Resultado:** imagem final ~100-150 MB vs ~700 MB se usasse apenas o builder

## Por que `mix release` e não `mix phx.server`?

| | `mix phx.server` | `mix release` |
|---|---|---|
| **Inclui Mix** | Sim (risco em prod) | Não |
| **Inclui código-fonte** | Sim | Não |
| **Tamanho da imagem** | ~600 MB+ | ~100-150 MB |
| **Hot code reload** | Suportado | Suportado (OTP nativo) |
| **Adequado para produção** | Não | Sim |

## Persistência do SQLite

O SQLite é um arquivo único em disco. Em Docker, arquivos dentro do container são efêmeros — morrem com o container. A solução é montar um **volume Docker** em `/data`:

```
# docker-compose.yml
volumes:
  - sqlite_data:/data   ← volume nomeado, gerenciado pelo Docker daemon
```

O volume sobrevive a:
- `docker-compose restart` — container reiniciado, dados preservados
- `docker-compose up --build` — imagem reconstruída, dados preservados
- `docker-compose down` — container removido, dados preservados
- `docker-compose down -v` — **DESTRÓI O VOLUME** (use com cautela)

## Migrações em Produção

Sem Mix disponível no release, as migrações são executadas via:

```bash
# Dentro do container (antes de iniciar o servidor):
bin/migrate

# Ou via docker exec após o container subir:
docker exec w_core bin/migrate
```

O script chama `WCore.Release.migrate/0`, que usa `Ecto.Migrator` diretamente — a mesma engine que o Mix usa internamente, sem precisar do Mix em si.

## Como usar

### Build e execução com docker-compose

```bash
# 1. Gerar uma SECRET_KEY_BASE segura
mix phx.gen.secret
# ou via openssl:
openssl rand -base64 48

# 2. Editar docker-compose.yml com a chave gerada

# 3. Build e start
docker compose up --build

# 4. Rodar migrações (primeiro start)
docker compose exec app bin/migrate

# 5. Acessar em http://localhost:4000
```

### Build manual

```bash
# Build da imagem
docker build -t w_core:latest .

# Rodar o container com volume persistente
docker run -d \
  --name w_core \
  -p 4000:4000 \
  -v w_core_data:/data \
  -e DATABASE_PATH=/data/w_core_prod.db \
  -e SECRET_KEY_BASE="<gerado com mix phx.gen.secret>" \
  -e PHX_HOST=localhost \
  w_core:latest
```

## Decisões Técnicas

### Por que SQLite?

O DCREADME especifica SQLite explicitamente. SQLite é adequado para:
- **Single-node deployments** (sem cluster de banco)
- **Simplicidade operacional** (sem servidor de banco separado)
- **Volume de leitura moderado** com ETS como cache na frente

O padrão Write-Behind implementado nos Steps 2-4 mitiga o principal limitante do SQLite (writes sequenciais), pois o ETS absorve o burst e o SQLite recebe apenas syncs periódicos em lote.

### Por que `libsqlite3-0` no runner?

O driver `ecto_sqlite3` usa NIF (Native Implemented Functions) — código C compilado que faz interface com a libsqlite3 do sistema. O builder compila o NIF; o runner precisa da biblioteca dinâmica `.so` instalada para o NIF funcionar em runtime.

### Limitação conhecida: sem migração automática no entrypoint

O `CMD` do Dockerfile inicia direto o servidor sem rodar `bin/migrate`. Isso é intencional: em ambientes com múltiplas réplicas, rodar migrações em todos os containers simultaneamente pode causar conflitos. A prática recomendada é:
- **Kubernetes:** usar um `initContainer` que roda `bin/migrate` antes dos pods principais
- **Docker Compose:** rodar `docker compose exec app bin/migrate` manualmente após o primeiro deploy
