# W-Core — Motor de Estado em Tempo Real

Motor de estado para monitoramento de sensores industriais da **Planta 42**, construído com Elixir + Phoenix LiveView + OTP + ETS + SQLite.

O sistema absorve picos de tráfego de milhares de sensores em memória (ETS), sincroniza com SQLite de forma assíncrona (Write-Behind) e exibe o estado das máquinas em tempo real via LiveView + PubSub — tudo sem perder um único evento.

---

## Arquitetura

```
Sensores (HTTP POST)
       │
       ▼
WCoreWeb.SensorController          ← valida a requisição
       │
       ▼ cast (async)
WCore.Telemetry.IngestServer       ← GenServer, fila de ingestão
       │
       ├─► WCore.Telemetry.Cache   ← ETS :set, update_counter atômico
       │         (hot state)
       │
       └─► Phoenix.PubSub          ← broadcast só em mudança de status
                 │
                 ▼
       WCoreWeb.DashboardLive      ← LiveView, O(1) update via map

WCore.Telemetry.WriteBehindWorker  ← GenServer, flush ETS→SQLite a cada 5s
       │
       ▼
    SQLite (WCore.Repo)            ← fonte de verdade persistente
```

**Supervisão OTP** (`:rest_for_one` — ordem importa):
```
WCore.Telemetry.Supervisor
  ├── Cache            (cria a tabela ETS primeiro)
  ├── IngestServer     (depende do ETS existir)
  └── WriteBehindWorker
```

---

## Pré-requisitos

| Ferramenta | Versão mínima |
|---|---|
| Erlang/OTP | 27 |
| Elixir | 1.18 |
| Docker | 24 (opcional, para deploy) |

**Windows:** Elixir em `C:\Program Files\Elixir\bin` e Erlang em `C:\Program Files\Erlang OTP\bin`. Adicione ambos ao PATH antes de usar o terminal.

---

## Rodando localmente

```bash
# 1. Instalar dependências e configurar o banco
mix setup

# 2. Iniciar o servidor
mix phx.server
```

Acesse [http://localhost:4000](http://localhost:4000).

> No Windows com Git Bash, o comando `iex` conflita com `Invoke-Expression` do PowerShell.
> Use `iex.bat -S mix phx.server` para rodar com console interativo.

---

## Criando um usuário

1. Acesse [http://localhost:4000/users/register](http://localhost:4000/users/register)
2. Crie uma conta
3. Acesse **Sala de Controle** na navbar

---

## Testando a API de sensores

O endpoint recebe pulsos de sensores autenticados por `machine_identifier`.

### Cadastrar um nó (via IEx)

```elixir
# No terminal interativo:
iex.bat -S mix

WCore.Telemetry.create_node(%{
  machine_identifier: "MACH-001",
  location: "Setor A"
})
```

### Enviar um pulso (curl)

```bash
curl -s -X POST http://localhost:4000/api/nodes/MACH-001/pulse \
  -H "Content-Type: application/json" \
  -d '{"status": "ok", "payload": {"temp": 72.4, "rpm": 1200}}'
```

**Status válidos:** `ok` | `warning` | `critical`

### Simular 10 máquinas com status aleatórios (Bash)

```bash
# Cadastra 10 nós via IEx primeiro:
iex.bat -S mix <<'EOF'
for i <- 1..10 do
  WCore.Telemetry.create_node(%{
    machine_identifier: "MACH-#{String.pad_leading("#{i}", 3, "0")}",
    location: "Setor #{div(i - 1, 3) + 1}"
  })
end
EOF

# Dispara 50 pulsos aleatórios em paralelo:
statuses=("ok" "ok" "ok" "warning" "critical")
for i in $(seq 1 50); do
  machine=$(printf "MACH-%03d" $((RANDOM % 10 + 1)))
  status=${statuses[$RANDOM % 5]}
  curl -s -X POST "http://localhost:4000/api/nodes/$machine/pulse" \
    -H "Content-Type: application/json" \
    -d "{\"status\": \"$status\", \"payload\": {\"seq\": $i}}" &
done
wait
echo "Pulsos enviados. Veja o dashboard em http://localhost:4000/dashboard"
```

---

## Rodando os testes

```bash
# Suite completa (103 testes)
mix test

# Apenas testes unitários do cache ETS (async, rápidos)
mix test test/w_core/telemetry/cache_test.exs

# Teste de caos: 10.000 eventos concorrentes
mix test test/w_core/telemetry_chaos_test.exs --trace
```

### O que os testes validam

| Arquivo | Tipo | O que prova |
|---|---|---|
| `cache_test.exs` | Unitário (async) | `update_counter` atômico, sem race condition, 100 upserts sequenciais |
| `telemetry_chaos_test.exs` | Integração (sync) | 10k eventos concorrentes → ETS conta exato → SQLite sincronizado |

**Saída esperada:**
```
103 tests, 0 failures
```

---

## Deploy com Docker

### Build e execução

```bash
# Build da imagem (multi-stage: builder ~600MB → runner ~150MB)
docker build -t w_core:latest .

# Gerar uma SECRET_KEY_BASE segura
openssl rand -base64 48

# Rodar o container com volume persistente para o SQLite
docker run -d \
  --name w_core \
  -p 4000:4000 \
  -v w_core_data:/data \
  -e DATABASE_PATH=/data/w_core_prod.db \
  -e SECRET_KEY_BASE="<chave gerada acima>" \
  -e PHX_HOST=localhost \
  w_core:latest

# Verificar logs
docker logs -f w_core
```

### Com docker-compose

```bash
# Editar docker-compose.yml com uma SECRET_KEY_BASE real, depois:
docker compose up --build
```

### Migrações

As migrações rodam automaticamente ao iniciar o container. Para rodar manualmente:

```bash
docker exec w_core bin/migrate
```

### Variáveis de ambiente

| Variável | Obrigatória | Descrição |
|---|---|---|
| `DATABASE_PATH` | Sim | Caminho do arquivo SQLite (ex: `/data/w_core_prod.db`) |
| `SECRET_KEY_BASE` | Sim | Chave de 64+ chars para assinar cookies (`openssl rand -base64 48`) |
| `PHX_HOST` | Não | Hostname da aplicação (padrão: `example.com`) |
| `PORT` | Não | Porta HTTP (padrão: `4000`) |

---

## Documentação técnica

Cada decisão arquitetural está documentada em `docs/drafts/`:

| Arquivo | Conteúdo |
|---|---|
| [step-1-foundation.md](docs/drafts/step-1-foundation.md) | Fundação: Phoenix, SQLite, autenticação, modelagem |
| [step-2-otp-ets.md](docs/drafts/step-2-otp-ets.md) | OTP: ETS, GenServers, Write-Behind pattern |
| [step-3-liveview-ds.md](docs/drafts/step-3-liveview-ds.md) | LiveView: PubSub, componentes HEEx, design system |
| [step-4-tests.md](docs/drafts/step-4-tests.md) | Testes: caos, concorrência, asserções de resiliência |
| [step-5-infra-arch.md](docs/drafts/step-5-infra-arch.md) | Infraestrutura: Dockerfile, release OTP, diagrama |

---

## Stack

- **Elixir 1.18** + **Erlang/OTP 27**
- **Phoenix 1.8.5** + **LiveView 1.1**
- **SQLite** via `ecto_sqlite3`
- **ETS** para estado em memória
- **Bandit** como servidor HTTP
- **DaisyUI + Tailwind CSS** para o design system
- **Docker** com build multi-estágio
