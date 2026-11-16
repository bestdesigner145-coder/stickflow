#!/bin/bash
# The report that chooses the model for structuring (spec 8.6, 18.3).
#
#   scripts/structure-report.sh [file with phrases of your own]
#
# Runs the set of phrases through the rules, through local models served by
# Ollama and, when ANTHROPIC_API_KEY is set, through Claude; writes
# ~/Desktop/stickflow-report.md. Phrases of your own go one per paragraph
# (a blank line between them); they are run and shown, not scored.
#
# What it does to the Mac: installs Ollama with Homebrew if it is missing,
# starts its server if it is not running, downloads the models (about 20 GB
# for the default three). Nothing is removed afterwards; the last lines say how.
#
#   MODELS="qwen3:8b gemma3:12b" scripts/structure-report.sh   # other models
#   OUT=report.md LIMIT=3 scripts/structure-report.sh          # elsewhere, fewer phrases
set -euo pipefail
cd "$(dirname "$0")/.."

MODELS="${MODELS:-hf.co/ai-sage/GigaChat3.1-10B-A1.8B-GGUF:Q4_K_M qwen3:8b gemma3:12b}"
OUT="${OUT:-$HOME/Desktop/stickflow-report.md}"
HOST="${OLLAMA_HOST_URL:-http://127.0.0.1:11434}"
FIXTURES="StickflowCore/Tests/StickflowCoreTests/StructuringFixtures/semantic.json"
PHRASES="${1:-}"

say() { printf '\n== %s\n' "$*"; }

command -v swift >/dev/null || { echo "Нужен Xcode или его Command Line Tools: xcode-select --install"; exit 1; }
if [ -n "$PHRASES" ] && [ ! -f "$PHRASES" ]; then echo "Нет файла с фразами: $PHRASES"; exit 1; fi

if ! command -v ollama >/dev/null; then
  if command -v brew >/dev/null; then
    say "Ставлю Ollama через Homebrew"
    brew install ollama
  else
    echo "Нужна Ollama: https://ollama.com/download — поставь и запусти скрипт ещё раз."
    exit 1
  fi
fi

if ! curl -fsS "$HOST/api/version" >/dev/null 2>&1; then
  say "Запускаю сервер Ollama (журнал: /tmp/stickflow-ollama.log)"
  (ollama serve >/tmp/stickflow-ollama.log 2>&1 &)
  for _ in $(seq 1 60); do
    curl -fsS "$HOST/api/version" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS "$HOST/api/version" >/dev/null || { echo "Сервер Ollama не поднялся, см. /tmp/stickflow-ollama.log"; exit 1; }
fi

say "Собираю отчётную программу"
swift build -c release --package-path StickflowCore --product stickflow-report
BIN="$(swift build -c release --package-path StickflowCore --show-bin-path)/stickflow-report"

ready=""
missing=""
for model in $MODELS; do
  say "Скачиваю $model"
  if ollama pull "$model"; then ready="${ready:+$ready,}$model"; else missing="$missing $model"; fi
done

chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '?')"
memory="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) ГБ"
system="macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"
ollama_version="$(ollama --version 2>/dev/null | tail -1 || true)"
machine="$chip, $memory, $system, $ollama_version"
[ -n "$missing" ] && machine="$machine. Не скачались:$missing"

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then echo "Claude: ключ найден, добавляю в сравнение."; else echo "Claude: ANTHROPIC_API_KEY не задан, сравнение без него."; fi

say "Считаю. На модель уходит несколько минут"
args=(--fixtures "$FIXTURES" --models "$ready" --host "$HOST" --machine "$machine" --output "$OUT")
[ -n "$PHRASES" ] && args+=(--phrases "$PHRASES")
[ -n "${LIMIT:-}" ] && args+=(--limit "$LIMIT")
"$BIN" "${args[@]}"

say "Готово: $OUT"
echo "Пришли этот файл. Модели остались в Ollama; убрать: ollama rm <модель> (список: ollama list)."
