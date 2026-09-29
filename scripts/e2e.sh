#!/usr/bin/env bash
# Teste de ponta a ponta do FIAP X contra o ambiente do docker-compose.
# Segue o roteiro de validação do relatório: cadastro, login, envio, acompanhamento,
# download, processamento paralelo, falha (DLQ) e isolamento entre usuários.
#
# Pré-requisitos: ambiente no ar (docker compose up -d --build), curl, jq, unzip e ffmpeg.
# Uso: ./scripts/e2e.sh
set -euo pipefail

API="${API_URL:-http://localhost:8080}"
RABBIT="${RABBIT_URL:-http://localhost:15672}"
WORK="$(mktemp -d)"
TIMEOUT="${E2E_TIMEOUT:-180}"

pass() { echo "  [OK] $*"; }
fail() { echo "  [FALHOU] $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

# Executa uma requisição e confere o status HTTP. Corpo da resposta vai para $WORK/resp.
call() {
  local expected="$1"; shift
  local code
  code=$(curl -s -o "$WORK/resp" -w '%{http_code}' "$@")
  [ "$code" = "$expected" ] || { cat "$WORK/resp" >&2; fail "esperado HTTP $expected, recebido $code ($*)"; }
}

# Espera o vídeo chegar ao status esperado.
wait_status() {
  local token="$1" id="$2" expected="$3" status=""
  for _ in $(seq 1 "$TIMEOUT"); do
    call 200 -H "Authorization: Bearer $token" "$API/api/videos/$id"
    status=$(jq -r .status "$WORK/resp")
    [ "$status" = "$expected" ] && return 0
    if [ "$status" = "ERRO" ] || [ "$status" = "CONCLUIDO" ]; then
      cat "$WORK/resp" >&2; fail "vídeo $id terminou em $status, esperado $expected"
    fi
    sleep 1
  done
  fail "vídeo $id não chegou a $expected em ${TIMEOUT}s (último status: $status)"
}

step "Aguardando a API ficar saudável"
for _ in $(seq 1 120); do
  if curl -sf "$API/actuator/health" | jq -e '.status == "UP"' >/dev/null 2>&1; then break; fi
  sleep 2
done
curl -sf "$API/actuator/health" | jq -e '.status == "UP"' >/dev/null || fail "API não respondeu UP em /actuator/health"
pass "API no ar"

step "Gerando vídeos de teste"
ffmpeg -loglevel error -f lavfi -i testsrc=duration=5:size=320x240:rate=25 -pix_fmt yuv420p "$WORK/video.mp4"
echo "isto nao e um video" > "$WORK/invalido.mp4"
pass "video.mp4 (5 s) e invalido.mp4 criados"

SUFFIX="$(date +%s)"
EMAIL1="teste1-$SUFFIX@fiapx.com"
EMAIL2="teste2-$SUFFIX@fiapx.com"

step "Passo 1 - Cadastro"
call 201 -X POST "$API/auth/register" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Usuario Teste\",\"email\":\"$EMAIL1\",\"password\":\"senha123\"}"
pass "usuário cadastrado (201)"

step "Passo 2 - Login"
call 200 -X POST "$API/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL1\",\"password\":\"senha123\"}"
TOKEN1=$(jq -r .token "$WORK/resp")
[ -n "$TOKEN1" ] && [ "$TOKEN1" != "null" ] || fail "login não devolveu token"
pass "token JWT recebido"

NOAUTH=$(curl -s -o /dev/null -w '%{http_code}' "$API/api/videos")
[ "$NOAUTH" = "401" ] || [ "$NOAUTH" = "403" ] || fail "rota sem token deveria ser recusada, recebido $NOAUTH"
pass "rota de vídeos sem token é recusada ($NOAUTH)"

step "Passo 3 - Envio do vídeo"
call 202 -X POST "$API/api/videos" -H "Authorization: Bearer $TOKEN1" -F "video=@$WORK/video.mp4"
ID=$(jq -r .videoId "$WORK/resp")
[ "$(jq -r .status "$WORK/resp")" = "RECEBIDO" ] || fail "status inicial diferente de RECEBIDO"
pass "vídeo $ID aceito (202, RECEBIDO)"

step "Passo 4 - Acompanhamento"
wait_status "$TOKEN1" "$ID" CONCLUIDO
FRAMES=$(jq -r .frameCount "$WORK/resp")
[ "$FRAMES" -ge 5 ] || fail "esperado ao menos 5 quadros, extraídos $FRAMES"
pass "vídeo $ID CONCLUIDO com $FRAMES quadros"

call 200 -H "Authorization: Bearer $TOKEN1" "$API/api/videos"
[ "$(jq '.content | length' "$WORK/resp")" -ge 1 ] || fail "listagem vazia"
pass "listagem do usuário contém o vídeo"

step "Passo 5 - Download"
call 200 -H "Authorization: Bearer $TOKEN1" "$API/api/videos/$ID/download"
cp "$WORK/resp" "$WORK/frames.zip"
PNGS=$(unzip -Z1 "$WORK/frames.zip" | grep -ci '\.png$' || true)
[ "$PNGS" = "$FRAMES" ] || fail "zip com $PNGS PNGs, esperado $FRAMES"
pass "frames.zip com $PNGS imagens PNG"

step "Processamento paralelo (3 vídeos ao mesmo tempo)"
IDS=()
for _ in 1 2 3; do
  call 202 -X POST "$API/api/videos" -H "Authorization: Bearer $TOKEN1" -F "video=@$WORK/video.mp4"
  IDS+=("$(jq -r .videoId "$WORK/resp")")
done
for id in "${IDS[@]}"; do wait_status "$TOKEN1" "$id" CONCLUIDO; done
pass "vídeos ${IDS[*]} concluídos"

step "Passo 6 - Falha no processamento"
call 202 -X POST "$API/api/videos" -H "Authorization: Bearer $TOKEN1" -F "video=@$WORK/invalido.mp4"
BAD=$(jq -r .videoId "$WORK/resp")
wait_status "$TOKEN1" "$BAD" ERRO
[ -n "$(jq -r '.errorMessage // empty' "$WORK/resp")" ] || fail "vídeo em ERRO sem errorMessage"
pass "vídeo $BAD marcado como ERRO com mensagem de falha"

DLQ=0
for _ in $(seq 1 15); do
  DLQ=$(curl -s -u guest:guest "$RABBIT/api/queues/%2F/video.process.dlq" | jq -r '.messages // 0')
  [ "$DLQ" -ge 1 ] && break
  sleep 2
done
[ "$DLQ" -ge 1 ] || fail "nenhuma mensagem na video.process.dlq"
pass "mensagem encaminhada para video.process.dlq ($DLQ na fila)"

call 409 -H "Authorization: Bearer $TOKEN1" "$API/api/videos/$BAD/download"
pass "download de vídeo não concluído é recusado (409)"

step "Passo 7 - Isolamento entre usuários"
call 201 -X POST "$API/auth/register" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Outro Usuario\",\"email\":\"$EMAIL2\",\"password\":\"senha123\"}"
TOKEN2=$(jq -r .token "$WORK/resp")
call 400 -H "Authorization: Bearer $TOKEN2" "$API/api/videos/$ID"
call 400 -H "Authorization: Bearer $TOKEN2" "$API/api/videos/$ID/download"
call 200 -H "Authorization: Bearer $TOKEN2" "$API/api/videos"
[ "$(jq '.content | length' "$WORK/resp")" = "0" ] || fail "segundo usuário enxerga vídeos do primeiro"
pass "segundo usuário não acessa nem lista os vídeos do primeiro"

echo
echo "Todos os passos do roteiro de validação passaram."
