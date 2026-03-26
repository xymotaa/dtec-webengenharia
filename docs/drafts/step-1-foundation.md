# Step 1 — Fundação e Perímetro de Segurança

## O que foi implementado

- Projeto Phoenix 1.8.5 criado com `mix phx.new` usando SQLite como banco de dados embutido
- Autenticação completa gerada via `phx.gen.auth` para o contexto `Accounts`
- Domínio `Telemetry` criado com dois schemas: `Node` e `NodeMetric`
- Migrations executadas e banco SQLite inicializado localmente

## Arquitetura
```
w_core/
├── lib/
│   ├── w_core/
│   │   ├── accounts/        # Contexto de autenticação (gerado pelo phx.gen.auth)
│   │   │   ├── user.ex
│   │   │   ├── user_token.ex
│   │   │   └── user_notifier.ex
│   │   ├── telemetry/       # Contexto de domínio dos sensores
│   │   │   ├── node.ex
│   │   │   └── node_metric.ex
│   │   └── repo.ex
│   └── w_core_web/          # Camada web (controllers, views, router)
└── priv/
    └── repo/
        └── migrations/      # Scripts de criação das tabelas
```

## Decisões Arquiteturais e Trade-offs

### Por que SQLite?
O desafio exige Edge Computing, o sistema roda localmente no servidor da planta, sem dependência de infraestrutura externa. O SQLite é um banco embutido, sem servidor separado, ideal para este cenário. O trade-off é que não escala horizontalmente, mas para um único nó de borda isso é uma vantagem, não um problema.

### Por que separar Accounts e Telemetry em contextos distintos?
Seguindo os princípios de separação de responsabilidades, o contexto `Accounts` cuida exclusivamente da identidade dos operadores, enquanto `Telemetry` cuida dos dados dos sensores. Isso evita acoplamento e facilita testes isolados de cada domínio.

### Por que duas tabelas no domínio Telemetry?
- `nodes`: dados estáticos dos sensores (identificador, localização). Raramente mudam.
- `node_metrics`: último estado conhecido de cada sensor. Atualizado frequentemente via upsert.

Essa separação evita que dados voláteis (métricas) poluam dados de referência (cadastro dos sensores), e permite que o mecanismo de Write-Behind (Passo 2) faça upserts eficientes apenas na tabela `node_metrics`.

### Por que phx.gen.auth e não uma biblioteca externa?
O desafio exige explicitamente o uso do `phx.gen.auth`. Além disso, gerar a autenticação nativamente dá controle total sobre o código — sem dependências opacas de terceiros, alinhado com a filosofia de sistemas críticos onde cada linha de código precisa ser auditável.