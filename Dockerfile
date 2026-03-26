# ────────────────────────────────────────────────────────────────────────────
# Stage 1 — builder
#   Compila a aplicação Elixir e gera os assets estáticos.
#   Usa a imagem oficial do Elixir baseada em Debian (slim) para ter as
#   ferramentas de build (mix, npm/node não são necessários — usamos esbuild
#   e tailwind que são binários baixados pelo Mix).
# ────────────────────────────────────────────────────────────────────────────
ARG ELIXIR_VERSION=1.18.3
ARG OTP_VERSION=27.3.1
ARG DEBIAN_VERSION=bookworm-20250317-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# Instala ferramentas de build do sistema operacional
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

# Instala o hex e o rebar (ferramentas padrão do ecossistema Elixir/Erlang)
RUN mix local.hex --force && \
    mix local.rebar --force

# Configura o ambiente de build como produção
ENV MIX_ENV="prod"

# Copia os manifestos de dependências primeiro para aproveitar o cache do Docker
# Se mix.exs/mix.lock não mudaram, o `mix deps.get` não roda novamente
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

# Copia e compila as dependências
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Compila os assets (esbuild + tailwind) — produz priv/static/assets/
COPY priv priv
COPY lib lib
COPY assets assets

RUN mix assets.deploy

# Compila o projeto e gera o release OTP
RUN mix compile

# Copia o restante das configurações (runtime.exs é lido em tempo de execução)
COPY config/runtime.exs config/

# Copia os scripts de release customizados (migrate, server)
COPY rel rel
RUN mix release

# ────────────────────────────────────────────────────────────────────────────
# Stage 2 — runner
#   Imagem mínima de produção. Não contém Elixir nem Mix — apenas o runtime
#   Erlang/OTP necessário para executar o release compilado.
#   Resultado final: imagem ~50-80 MB vs ~600 MB do builder.
# ────────────────────────────────────────────────────────────────────────────
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales libsqlite3-0 \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Define o locale para UTF-8 — evita problemas com caracteres especiais
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG="en_US.UTF-8"
ENV LANGUAGE="en_US:en"
ENV LC_ALL="en_US.UTF-8"

WORKDIR "/app"
RUN chown nobody /app

# Define o caminho do banco de dados SQLite como variável de ambiente.
# O valor padrão aponta para o volume montado em /data.
# Sobrescreva com DATABASE_PATH ao rodar o container se necessário.
ENV DATABASE_PATH="/data/w_core_prod.db"
ENV PHX_SERVER="true"

# Copia o release do estágio builder para a imagem runner
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/w_core ./

USER nobody

# Expõe a porta padrão da aplicação Phoenix
EXPOSE 4000

# Cria o diretório de dados (o volume será montado aqui em runtime)
# VOLUME é declarativo — informa ao Docker que /data deve ser persistido
VOLUME ["/data"]

# Inicia o servidor Phoenix via script gerado pelo mix release
CMD ["/app/bin/server"]
