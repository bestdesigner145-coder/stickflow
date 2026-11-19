#!/bin/bash
# Builds the branch that is checked out and runs it in place of whatever copy
# of Stickflow is running now.
#
#   git pull && scripts/run.sh
#
# The menu-bar menu then says which build it is: "Build 17.11 11:40 · 78793aa".
# `scripts/run.sh --build-only` stops before the app is started.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodebuild >/dev/null || { echo "Нужен Xcode."; exit 1; }
if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || { echo "Нужен XcodeGen: brew install xcodegen"; exit 1; }
  brew install xcodegen
fi

commit="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
echo "== Ветка ${branch}, коммит ${commit}"
dirty="$(git status --porcelain 2>/dev/null)"
if [ -n "${dirty}" ]; then echo "   Есть несохранённые правки: сборка будет с ними."; fi

# The project is generated: without this, files added since the last pull are not in it.
xcodegen generate --quiet

echo "== Собираю"
xcodebuild build \
  -project Stickflow.xcodeproj \
  -scheme Stickflow \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  STICKFLOW_COMMIT="${commit}" \
  -quiet

app="build/DerivedData/Build/Products/Debug/Stickflow.app"
# A build must not change files in the repository: the next `git pull` would stop (spec 18.10 E2).
if [ -n "$(git status --porcelain 2>/dev/null)" ] && [ -z "${dirty}" ]; then
  echo "== Сборка изменила файлы репозитория:"
  git status --short
fi
[ -d "${app}" ] || { echo "Сборка не дала ${app}"; exit 1; }
if [ "${1:-}" = "--build-only" ]; then echo "== Собрано: ${app}"; exit 0; fi

# One Stickflow at a time: an older copy would keep showing the old behaviour.
if pkill -x Stickflow 2>/dev/null; then echo "== Закрыл запущенную копию"; sleep 1; fi
open "${app}"
echo "== Запущено. В меню иконки в строке меню: «Сборка … · ${commit}»."
