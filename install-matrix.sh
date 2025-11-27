# install-matrix.sh
#!/usr/bin/env bash
set -euo pipefail

# URL git-репозитория с этим проектом.
# ОБЯЗАТЕЛЬНО замени на реальный URL перед первым использованием.
REPO_URL="${REPO_URL:-https://github.com/YOUR_GITHUB_USER/YOUR_REPO.git}"

# Каталог, куда будет клонироваться проект на сервере
APP_DIR="${APP_DIR:-/opt/matrix-homeserver}"

if [[ "$EUID" -ne 0 ]]; then
  echo "Этот скрипт нужно запускать от root (через sudo)." >&2
  exit 1
fi

echo "[*] Установка системных зависимостей (git, Docker, docker compose)…"
apt-get update -y
apt-get install -y git ca-certificates curl docker.io docker-compose-plugin

systemctl enable --now docker

if [[ ! -d "$APP_DIR/.git" ]]; then
  echo "[*] Клонируем репозиторий в $APP_DIR…"
  rm -rf "$APP_DIR"
  git clone "$REPO_URL" "$APP_DIR"
else
  echo "[*] Репозиторий уже существует, обновляем…"
  git -C "$APP_DIR" pull --ff-only
fi

cd "$APP_DIR"

if [[ ! -f ".env" ]]; then
  if [[ -f ".env.example" ]]; then
    cp .env.example .env
    echo
    echo "[*] Создан файл .env на основе .env.example."
    echo "    Обязательно отредактируй .env (MATRIX_SERVER_NAME, MATRIX_ADMIN_EMAIL, POSTGRES_PASSWORD)"
    echo "    и запусти install-matrix.sh ещё раз."
    exit 0
  else
    echo "ОШИБКА: не найден .env и .env.example. Проверь репозиторий." >&2
    exit 1
  fi
fi

echo "[*] Загружаем переменные из .env…"
set -a
# shellcheck disable=SC1091
source .env
set +a

mkdir -p data/synapse data/postgres data/caddy-data data/caddy-config

if [[ -z "${MATRIX_SERVER_NAME:-}" ]]; then
  echo "ОШИБКА: в .env не задан MATRIX_SERVER_NAME." >&2
  exit 1
fi

if [[ -z "${POSTGRES_PASSWORD:-}" || "${POSTGRES_PASSWORD}" == "CHANGE_ME_PLEASE" ]]; then
  echo "ОШИБКА: задай сильный POSTGRES_PASSWORD в .env (не используй CHANGE_ME_PLEASE)." >&2
  exit 1
fi

if [[ ! -f "data/synapse/homeserver.yaml" ]]; then
  echo "[*] homeserver.yaml не найден. Генерируем конфигурацию Synapse…"
  docker run -it --rm \
    -v "$PWD/data/synapse:/data" \
    -e SYNAPSE_SERVER_NAME="${MATRIX_SERVER_NAME}" \
    -e SYNAPSE_REPORT_STATS="${SYNAPSE_REPORT_STATS:-no}" \
    matrixdotorg/synapse:latest generate

  echo
  echo "[*] Конфигурация Synapse создана: $PWD/data/synapse/homeserver.yaml"
  echo "    Перед запуском контейнеров отредактируй этот файл:"
  echo "      - в секции database укажи PostgreSQL:"
  echo "          name: psycopg2"
  echo "          host: db"
  echo "          user: \${POSTGRES_USER} из .env"
  echo "          password: \${POSTGRES_PASSWORD} из .env"
  echo "          database: \${POSTGRES_DB} из .env"
  echo "      - убедись, что HTTP listener слушает порт 8008, tls: false, x_forwarded: true."
  echo
  echo "После правки запусти install-matrix.sh ещё раз."
  exit 0
fi

echo "[*] Обновляем образы Docker…"
docker compose pull

echo "[*] Запускаем контейнеры…"
docker compose up -d

echo

echo "[*] Стек Matrix Synapse запущен."
echo "Проверь доступность API (замени домен на свой):"
echo "  curl https://${MATRIX_SERVER_NAME}/_matrix/client/versions"
echo "  curl -k https://${MATRIX_SERVER_NAME}:8448/_matrix/federation/v1/version"
