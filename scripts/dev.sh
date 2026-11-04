#!/usr/bin/env bash
# Run everything locally: the image service (SDXL-Turbo on this Mac's GPU),
# the client build, and the game server. Ollama must already be running
# natively (`ollama serve` or the Ollama app) — not in Docker, which on a Mac
# has no GPU access.
#
#   scripts/dev.sh            # http://localhost:4300
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }

export OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"
export IMAGE_API_BASE_URL="${IMAGE_API_BASE_URL:-http://localhost:7860}"
export DB_PATH="${DB_PATH:-$ROOT/data/inkmud.db}"
export ART_DIR="${ART_DIR:-$ROOT/data/art}"
# Developer actions (the Reset world button). Never set this in production.
export DEV_TOOLS="${DEV_TOOLS:-1}"
mkdir -p "$ROOT/data"

if ! curl -sf "$OLLAMA_BASE_URL/api/tags" >/dev/null; then
  echo "==> Ollama isn't answering at $OLLAMA_BASE_URL. Start it with: ollama serve" >&2
  exit 1
fi
for model in "${FAST_MODEL:-llama3.2:3b}" "${BUILDER_MODEL:-llama3.2:3b}"; do
  curl -sf "$OLLAMA_BASE_URL/api/tags" | grep -q "\"$model\"" || {
    echo "==> Model $model is not pulled. Run: ollama pull $model" >&2; exit 1; }
done

if ! curl -sf "$IMAGE_API_BASE_URL/health" >/dev/null; then
  echo "==> Starting image service (first start loads SDXL-Turbo, ~10 s)"
  (cd "$ROOT/imagegen" && uv run --extra local python server.py) &
  IMAGEGEN_PID=$!
  trap 'kill $IMAGEGEN_PID 2>/dev/null || true' EXIT
  for _ in $(seq 1 120); do
    curl -sf "$IMAGE_API_BASE_URL/health" >/dev/null && break
    sleep 1
  done
fi

"$ROOT/scripts/build-client.sh"
cd "$ROOT/server"
gleam run
