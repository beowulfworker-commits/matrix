#!/usr/bin/env bash
set -Eeuo pipefail

# Matrix Synapse + PostgreSQL + Caddy(ACME) + опц. coturn + Synapse-Admin
# Debian 12 / Ubuntu 22.04 / 24.04

# -------- defaults --------
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
ADMIN_USER="${ADMIN_USER:-}"
ADMIN_PASS="${ADMIN_PASS:-}"
DB_PASS="${DB_PASS:-}"
INSTALL_TURN="${INSTALL_TURN:-yes}"          # yes|no
CONFIGURE_UFW="${CONFIGURE_UFW:-auto}"       # auto|yes|no
INSTALL_ADMIN_UI="${INSTALL_ADMIN_UI:-yes}"  # yes|no

PG_USER="synapse"
PG_DB="synapse"
SECRETS_FILE="/root/matrix_install_secrets.txt"
ADMIN_UI_PORT="8081"
ADMIN_UI_PATH="/admin"
CADDYFILE="/etc/caddy/Caddyfile"

log(){ echo "[*] $*"; }
warn(){ echo "[!] $*" >&2; }
die(){ echo "[x] $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
secret_hex(){ openssl rand -hex 32; }
need_root(){ [[ $EUID -eq 0 ]] || die "Нужны права root"; }
os_check(){ . /etc/os-release; [[ "$ID" =~ (debian|ubuntu) ]] || die "Поддерживаются Debian/Ubuntu"; }

ask(){ local p="$1" d="${2:-}"; local v; read -rp "$p${d:+ [$d]}: " v; echo "${v:-$d}"; }
ask_pass(){ local v; read -rsp "$1: " v; echo; echo "$v"; }
ask_yesno(){ local p="$1" d="${2:-yes}"; local v; read -rp "$p [yes/no] (default $d): " v; v="${v:-$d}"; [[ "${v,,}" =~ ^y ]] && echo yes || echo no; }

# -------- input --------
wizard(){
  [[ -n "$DOMAIN" ]] || DOMAIN="$(ask 'Домен (FQDN для Matrix)')"
  [[ -n "$EMAIL"  ]] || EMAIL="$(ask 'E-mail для ACME' "admin@${DOMAIN}")"
  INSTALL_TURN="$(ask_yesno 'Установить coturn для звонков?' "$INSTALL_TURN")"
  INSTALL_ADMIN_UI="$(ask_yesno 'Установить панель Synapse-Admin?' "$INSTALL_ADMIN_UI")"
  CONFIGURE_UFW="$(ask 'Настройка UFW: auto/yes/no' "$CONFIGURE_UFW")"
  [[ -n "$DB_PASS" ]] || DB_PASS="$(ask 'Пароль PostgreSQL пользователя synapse (Enter — автогенерация)')"
  if [[ "$(ask_yesno 'Создать администратора сейчас?' 'no')" == "yes" ]]; then
    ADMIN_USER="$(ask "Имя админа (без @ и :$DOMAIN)" "${ADMIN_USER:-admin}")"
    [[ -n "$ADMIN_PASS" ]] || ADMIN_PASS="$(ask_pass 'Пароль админа')"
  fi
}

# -------- packages --------
stop_disable_nginx(){
  if systemctl list-unit-files | grep -q '^nginx\.service'; then
    log "Отключаю Nginx"
    systemctl stop nginx || true
    systemctl disable nginx || true
  fi
}
install_base(){
  log "Базовые пакеты"
  apt-get update -y
  apt-get install -y curl wget gnupg lsb-release ca-certificates jq openssl debconf-utils \
                     postgresql libpq5 pwgen docker.io
  systemctl enable --now postgresql
  systemctl enable --now docker
}

# -------- Caddy repo (один signed-by, без sed) --------
install_caddy(){
  log "Установка Caddy"
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

  rm -f /etc/apt/sources.list.d/caddy-stable.list
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    > /etc/apt/sources.list.d/caddy-stable.list

  apt-get update -y
  apt-get install -y caddy
  systemctl enable --now caddy
}

# -------- Synapse --------
add_matrix_repo(){
  log "Добавляю репозиторий matrix.org"
  install -m 0755 -d /usr/share/keyrings
  wget -O /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/matrix-org.list
  apt-get update -y
}
install_synapse_pkg(){
  log "Установка Synapse"
  echo "matrix-synapse-py3 matrix-synapse/server-name string $DOMAIN" | debconf-set-selections
  echo "matrix-synapse-py3 matrix-synapse/report-stats boolean false"  | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt-get install -y matrix-synapse-py3
}
setup_db(){
  log "PostgreSQL: пользователь и БД"
  DB_PASS="${DB_PASS:-$(secret_hex)}"
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${PG_USER}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER ${PG_USER} WITH PASSWORD '${DB_PASS}';"
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${PG_DB}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE ${PG_DB} OWNER ${PG_USER} ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;"
}
configure_synapse(){
  log "Конфигурация Synapse (conf.d)"
  local REG_SECRET="$(secret_hex)"
  local TURN_SECRET="$(secret_hex)"
  install -d -m 0750 /etc/matrix-synapse/conf.d
  cat >/etc/matrix-synapse/conf.d/90-local.yaml <<YAML
public_baseurl: "https://${DOMAIN}/"
enable_registration: false
registration_shared_secret: "${REG_SECRET}"
max_upload_size: "50M"
database:
  name: psycopg2
  args:
    user: "${PG_USER}"
    password: "${DB_PASS}"
    dbname: "${PG_DB}"
    host: "127.0.0.1"
    port: 5432
    cp_min: 5
    cp_max: 20
YAML
  grep -q '^x_forwarded:' /etc/matrix-synapse/homeserver.yaml || echo -e "\nx_forwarded: true" >> /etc/matrix-synapse/homeserver.yaml
  if [[ "$INSTALL_TURN" == "yes" ]]; then
    cat >>/etc/matrix-synapse/conf.d/90-local.yaml <<YAML
turn_uris:
  - "turn:${DOMAIN}:3478?transport=udp"
  - "turn:${DOMAIN}:3478?transport=tcp"
turn_shared_secret: "${TURN_SECRET}"
turn_user_lifetime: "1h"
YAML
  fi
  chown -R matrix-synapse:matrix-synapse /etc/matrix-synapse/conf.d
  systemctl restart matrix-synapse
  cat >"$SECRETS_FILE" <<OUT
Matrix server: https://${DOMAIN}
PostgreSQL: user=${PG_USER} db=${PG_DB} password=${DB_PASS}
registration_shared_secret: ${REG_SECRET}
turn_shared_secret: ${TURN_SECRET}
OUT
  chmod 600 "$SECRETS_FILE"
}

# -------- Caddyfile (исправленный /admin/, отключен кеш) --------
write_caddyfile(){
  log "Caddyfile"
  stop_disable_nginx
  cat >"$CADDYFILE" <<'CADDY'
{
  email __EMAIL__
}

__DOMAIN__ {
  encode zstd gzip
  # Белый экран после обновлений: не кешируем SPA
  header /admin/* Cache-Control "no-store"

  @well_server path /.well-known/matrix/server
  handle @well_server {
    header Content-Type "application/json"
    header Access-Control-Allow-Origin "*"
    respond "{\"m.server\":\"__DOMAIN__:443\"}"
  }

  @well_client path /.well-known/matrix/client
  handle @well_client {
    header Content-Type "application/json"
    header Access-Control-Allow-Origin "*"
    respond "{\"m.homeserver\":{\"base_url\":\"https://__DOMAIN__\"}}"
  }

  # Панель под префиксом /admin: отрезаем префикс и отдаём контейнеру
  handle_path /admin/* {
    reverse_proxy 127.0.0.1:__ADMIN_PORT__
  }
  redir /admin /admin/ 301

  # Matrix client + admin API
  reverse_proxy /_matrix/* 127.0.0.1:8008
  reverse_proxy /_synapse/* 127.0.0.1:8008
}

__DOMAIN__:8448 {
  encode zstd gzip
  reverse_proxy /_matrix/* 127.0.0.1:8008
  reverse_proxy /_synapse/* 127.0.0.1:8008
}
CADDY
  sed -i "s/__DOMAIN__/${DOMAIN}/g" "$CADDYFILE"
  sed -i "s/__EMAIL__/${EMAIL}/g" "$CADDYFILE"
  sed -i "s/__ADMIN_PORT__/${ADMIN_UI_PORT}/g" "$CADDYFILE"
  caddy validate --config "$CADDYFILE"
  systemctl reload caddy || systemctl restart caddy
}

# -------- TURN --------
install_turn(){
  [[ "$INSTALL_TURN" == "yes" ]] || return 0
  log "Установка coturn"
  apt-get install -y coturn
  if grep -q '^#\?TURNSERVER_ENABLED' /etc/default/coturn 2>/dev/null; then
    sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
  else
    echo 'TURNSERVER_ENABLED=1' >> /etc/default/coturn
  fi
  cp -a /etc/turnserver.conf /etc/turnserver.conf.bak.$(date +%s) 2>/dev/null || true
  local TURN_SECRET="$(awk '/turn_shared_secret:/ {print $2}' "$SECRETS_FILE" 2>/dev/null || secret_hex)"
  local PUBLIC_IP
  PUBLIC_IP="$(curl -fsS https://ifconfig.co)"
  PUBLIC_IP="${PUBLIC_IP//$'\n'/}"
  cat >/etc/turnserver.conf <<CONF
use-auth-secret
static-auth-secret=${TURN_SECRET}
realm=${DOMAIN}
syslog
no-tcp-relay
no-multicast-peers
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=240.0.0.0-255.255.255.255
listening-port=3478
tls-listening-port=5349
external-ip=${PUBLIC_IP}
CONF
  systemctl enable --now coturn
}

# -------- Synapse-Admin --------
install_synapse_admin(){
  [[ "$INSTALL_ADMIN_UI" == "yes" ]] || return 0
  log "Synapse-Admin (Docker)"
  install -d -m 0755 /var/lib/synapse-admin
  cat >/var/lib/synapse-admin/config.json <<CFG
{ "restrictBaseUrl": "https://${DOMAIN}" }
CFG
  docker rm -f synapse-admin >/dev/null 2>&1 || true
  docker run -d --name synapse-admin --restart unless-stopped \
    -p 127.0.0.1:${ADMIN_UI_PORT}:80 \
    -v /var/lib/synapse-admin/config.json:/app/config.json:ro \
    awesometechnologies/synapse-admin:latest
}

# -------- UFW --------
configure_ufw(){
  [[ "$CONFIGURE_UFW" == "no" ]] && return 0
  if have ufw && ufw status | grep -q "Status: active"; then
    log "Открываю порты в UFW"
    ufw allow 80,443,8448/tcp || true
    [[ "$INSTALL_TURN" == "yes" ]] && { ufw allow 3478/tcp || true; ufw allow 3478/udp || true; ufw allow 5349/tcp || true; ufw allow 49152:65535/udp || true; }
  fi
}

# -------- Admin user + health --------
create_admin_user(){
  [[ -n "$ADMIN_USER" && -n "$ADMIN_PASS" ]] || return 0
  log "Создание @${ADMIN_USER}:${DOMAIN}"
  local REG_SECRET
  REG_SECRET="$(awk '/registration_shared_secret:/ {print $2}' "$SECRETS_FILE")"
  if [[ -z "$REG_SECRET" ]]; then
    warn "registration_shared_secret не найден в $SECRETS_FILE"
    return 0
  fi
  # ВАЖНО: использовать -k и -H
  register_new_matrix_user \
    -k "$REG_SECRET" \
    -u admin \
    -p 'Kavabanga321' \
    -a \
    http://127.0.0.1:8008
}
health_check(){
  log "Проверка (ждём авто‑TLS Caddy)"
  for i in {1..60}; do
    code=$(curl -ks -o /dev/null -w "%{http_code}" "https://${DOMAIN}/_matrix/client/versions" || true)
    [[ "$code" == "200" ]] && break || sleep 1
  done
  echo "client versions -> ${code:-0}"
  echo "admin version  -> $(curl -ks -o /dev/null -w "%{http_code}" "https://${DOMAIN}/_synapse/admin/v1/server_version" || true)"
}

# -------- Full install --------
full_install(){
  [[ -n "$DOMAIN" && -n "$EMAIL" ]] || wizard
  stop_disable_nginx
  install_base
  install_caddy
  add_matrix_repo
  install_synapse_pkg
  setup_db
  configure_synapse
  install_synapse_admin
  write_caddyfile
  install_turn
  configure_ufw
  create_admin_user
  log "Секреты: $SECRETS_FILE"
  health_check
  log "Готово. Панель: https://${DOMAIN}${ADMIN_UI_PATH}/"
}

# -------- flags --------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2;;
    --email) EMAIL="${2:-}"; shift 2;;
    --admin-user) ADMIN_USER="${2:-}"; shift 2;;
    --admin-pass) ADMIN_PASS="${2:-}"; shift 2;;
    --db-pass) DB_PASS="${2:-}"; shift 2;;
    --no-turn) INSTALL_TURN="no"; shift;;
    --admin-ui) INSTALL_ADMIN_UI="yes"; shift;;
    --no-admin-ui) INSTALL_ADMIN_UI="no"; shift;;
    --ufw) CONFIGURE_UFW="${2:-auto}"; shift 2;;
    -h|--help)
      cat <<USAGE
Usage:
  $0  # вопросы в консоли -> полная установка
  $0 --domain d --email e [--admin-user u --admin-pass p] [--db-pass P] [--admin-ui|--no-admin-ui] [--no-turn] [--ufw auto|yes|no]
USAGE
      exit 0;;
    *) die "Неизвестный параметр: $1";;
  esac
done

need_root
os_check
full_install
