#!/usr/bin/env bash
set -Eeuo pipefail

# Installer for Matrix Synapse + PostgreSQL + Caddy on Ubuntu 24.04
# Optional extras: coturn and Synapse-Admin (Docker)

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
ADMIN_USER="${ADMIN_USER:-}"
ADMIN_PASS="${ADMIN_PASS:-}"
DB_PASS="${DB_PASS:-}"
INSTALL_TURN="${INSTALL_TURN:-yes}"      # yes|no
INSTALL_ADMIN_UI="${INSTALL_ADMIN_UI:-yes}"  # yes|no
CONFIGURE_UFW="${CONFIGURE_UFW:-yes}"    # yes|no
ADMIN_UI_PORT="8081"
ADMIN_UI_PATH="/admin"
PG_USER="synapse"
PG_DB="synapse"
SECRETS_FILE="/root/matrix_install_secrets.txt"

log(){ echo "[*] $*"; }
warn(){ echo "[!] $*" >&2; }
die(){ echo "[x] $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
secret_hex(){ openssl rand -hex 32; }

require_root(){ [[ $EUID -eq 0 ]] || die "Запустите от root"; }
require_ubuntu24(){
  . /etc/os-release
  [[ "$ID" == "ubuntu" && "$VERSION_ID" =~ ^24 ]] || die "Только Ubuntu 24.04";
}

prompt(){ local msg="$1" def="${2:-}"; local v; read -rp "$msg${def:+ [$def]}: " v; echo "${v:-$def}"; }
prompt_pass(){ local msg="$1"; local v; read -rsp "$msg: " v; echo; echo "$v"; }
prompt_yesno(){ local msg="$1" def="${2:-yes}"; local v; read -rp "$msg [yes/no] (default $def): " v; v="${v:-$def}"; [[ "${v,,}" =~ ^y ]] && echo yes || echo no; }

collect_input(){
  [[ -n "$DOMAIN" ]] || DOMAIN="$(prompt 'Matrix домен (FQDN)')"
  [[ -n "$EMAIL"  ]] || EMAIL="$(prompt 'E-mail для ACME' "admin@${DOMAIN}")"
  INSTALL_TURN="$(prompt_yesno 'Установить coturn?' "$INSTALL_TURN")"
  INSTALL_ADMIN_UI="$(prompt_yesno 'Установить Synapse-Admin?' "$INSTALL_ADMIN_UI")"
  CONFIGURE_UFW="$(prompt_yesno 'Настроить UFW?' "$CONFIGURE_UFW")"
  [[ -n "$DB_PASS" ]] || DB_PASS="$(prompt 'Пароль PostgreSQL (enter — авто)' '')"
  if [[ -z "$DB_PASS" ]]; then
    DB_PASS="$(secret_hex)"
    log "Пароль БД сгенерирован"
  fi
  if [[ "$(prompt_yesno 'Создать администратора Matrix?' 'no')" == "yes" ]]; then
    [[ -n "$ADMIN_USER" ]] || ADMIN_USER="$(prompt 'Имя админа (без @)' 'admin')"
    [[ -n "$ADMIN_PASS" ]] || ADMIN_PASS="$(prompt_pass 'Пароль админа')"
  fi
}

stop_disable_nginx(){
  if systemctl list-unit-files | grep -q '^nginx\.service'; then
    log "Отключаю Nginx"
    systemctl stop nginx || true
    systemctl disable nginx || true
  fi
}

install_packages(){
  log "Установка пакетов"
  apt-get update -y
  apt-get install -y curl wget gnupg lsb-release ca-certificates jq openssl debconf-utils \
                     postgresql libpq5 docker.io pwgen
  systemctl enable --now postgresql
  systemctl enable --now docker
}

install_caddy(){
  log "Установка Caddy"
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
  systemctl enable --now caddy
}

add_matrix_repo(){
  log "Добавляю репозиторий matrix.org"
  install -m 0755 -d /usr/share/keyrings
  wget -O /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/matrix-org.list
  apt-get update -y
}

install_synapse(){
  log "Установка Synapse"
  echo "matrix-synapse-py3 matrix-synapse/server-name string $DOMAIN" | debconf-set-selections
  echo "matrix-synapse-py3 matrix-synapse/report-stats boolean false"  | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt-get install -y matrix-synapse-py3
}

setup_postgres(){
  log "Настраиваю PostgreSQL"
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${PG_USER}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER ${PG_USER} WITH PASSWORD '${DB_PASS}';"
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${PG_DB}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE ${PG_DB} OWNER ${PG_USER} ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;"
}

configure_synapse(){
  log "Конфигурация Synapse"
  local REG_SECRET="$(secret_hex)"
  install -d -m 0750 /etc/matrix-synapse/conf.d
  cat >/etc/matrix-synapse/conf.d/90-local.yaml <<YAML
server_name: "${DOMAIN}"
public_baseurl: "https://${DOMAIN}/"
enable_registration: false
registration_shared_secret: "${REG_SECRET}"
max_upload_size: "50M"
database:
  name: psycopg2
  args:
    user: "${PG_USER}"
    password: "${DB_PASS}"
    database: "${PG_DB}"
    host: "localhost"
    cp_min: 5
    cp_max: 10
YAML
  cat >"${SECRETS_FILE}" <<SEC
DOMAIN=${DOMAIN}
DB_PASS=${DB_PASS}
REGISTRATION_SECRET=${REG_SECRET}
SEC
  chmod 600 "${SECRETS_FILE}"
  systemctl restart matrix-synapse
}

install_turn(){
  [[ "$INSTALL_TURN" == "yes" ]] || return 0
  log "Установка coturn"
  apt-get install -y coturn
  local TURN_SECRET="$(secret_hex)"
  local PUBLIC_IP
  PUBLIC_IP=$(curl -4 -fs https://ifconfig.co || curl -4 -fs https://ipecho.net/plain || true)
  cat >/etc/turnserver.conf <<CONF
use-auth-secret
static-auth-secret=${TURN_SECRET}
realm=${DOMAIN}
syslog
no-tcp-relay
no-multicast-peers
listening-port=3478
tls-listening-port=5349
$( [[ -n "$PUBLIC_IP" ]] && echo "external-ip=${PUBLIC_IP}" )
CONF
  cat >>"${SECRETS_FILE}" <<SEC
TURN_SECRET=${TURN_SECRET}
SEC
  systemctl enable --now coturn
}

install_synapse_admin(){
  [[ "$INSTALL_ADMIN_UI" == "yes" ]] || return 0
  log "Разворачиваю Synapse-Admin"
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

write_caddyfile(){
  log "Caddyfile"
  cat > /etc/caddy/Caddyfile <<CADDY
${DOMAIN} {
  encode gzip zstd
  tls ${EMAIL}
  reverse_proxy /_matrix/* 127.0.0.1:8008
  reverse_proxy /_synapse/client/* 127.0.0.1:8008
  @admin path ${ADMIN_UI_PATH}*
  reverse_proxy @admin 127.0.0.1:${ADMIN_UI_PORT}
}
CADDY
  systemctl reload caddy
}

configure_ufw(){
  [[ "$CONFIGURE_UFW" == "yes" ]] || return 0
  if have ufw && ufw status | grep -q "Status: active"; then
    log "Настраиваю UFW"
    ufw allow 80,443,8448/tcp || true
    [[ "$INSTALL_TURN" == "yes" ]] && { ufw allow 3478,5349/tcp || true; ufw allow 3478/udp || true; ufw allow 49152:65535/udp || true; }
  fi
}

create_admin_user(){
  [[ -n "$ADMIN_USER" && -n "$ADMIN_PASS" ]] || return 0
  log "Создание администратора"
  local REG_SECRET
  REG_SECRET="$(awk -F'=' '/REGISTRATION_SECRET/ {print $2}' "$SECRETS_FILE")"
  register_new_matrix_user -k "$REG_SECRET" -u "$ADMIN_USER" -p "$ADMIN_PASS" -a http://127.0.0.1:8008
}

health_check(){
  log "Проверка"
  for _ in {1..60}; do
    code=$(curl -ks -o /dev/null -w "%{http_code}" "https://${DOMAIN}/_matrix/client/versions" || true)
    [[ "$code" == "200" ]] && break || sleep 1
  done
  echo "Matrix versions -> ${code:-0}"
}

main(){
  require_root
  require_ubuntu24
  collect_input
  stop_disable_nginx
  install_packages
  install_caddy
  add_matrix_repo
  install_synapse
  setup_postgres
  configure_synapse
  install_turn
  install_synapse_admin
  write_caddyfile
  configure_ufw
  create_admin_user
  log "Секреты сохранены в ${SECRETS_FILE}"
  health_check
  log "Готово! Панель (если включена): https://${DOMAIN}${ADMIN_UI_PATH}/"
}

main "$@"
