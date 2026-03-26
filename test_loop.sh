#!/usr/bin/env bash
# Teste de carga: 50 máquinas, loop infinito de pulsos
# Uso: bash test_loop.sh

BASE_URL="http://localhost:4000"
MACHINES=50
STATUSES=("ok" "ok" "ok" "ok" "warning" "warning" "critical")
SEQ=0

echo "==> Cadastrando $MACHINES nós via IEx..."
iex.bat -S mix 2>/dev/null <<'ELIXIR'
for i <- 1..50 do
  WCore.Telemetry.create_node(%{
    machine_identifier: "MACH-#{String.pad_leading("#{i}", 3, "0")}",
    location: "Setor #{div(i - 1, 10) + 1}"
  })
end
IO.puts("Nós cadastrados.")
ELIXIR

echo ""
echo "==> Iniciando loop de pulsos (Ctrl+C para parar)..."
echo ""

while true; do
  SEQ=$((SEQ + 1))
  ROUND_START=$(date +%s%3N)

  for i in $(seq 1 $MACHINES); do
    machine=$(printf "MACH-%03d" "$i")
    status=${STATUSES[$RANDOM % ${#STATUSES[@]}]}
    temp=$(echo "scale=1; ($RANDOM % 500 + 600) / 10" | bc)
    rpm=$((RANDOM % 2000 + 800))

    curl -s -o /dev/null -X POST "$BASE_URL/api/nodes/$machine/pulse" \
      -H "Content-Type: application/json" \
      -d "{\"status\": \"$status\", \"payload\": {\"seq\": $SEQ, \"temp\": $temp, \"rpm\": $rpm}}" &
  done

  wait

  ROUND_END=$(date +%s%3N)
  ELAPSED=$((ROUND_END - ROUND_START))
  echo "Round $SEQ — $MACHINES pulsos em ${ELAPSED}ms  [$(date '+%H:%M:%S')]"

  sleep 1
done
