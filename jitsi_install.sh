#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION=stable-11248-3
UPSTREAM_COMMIT=fca3e3a578a1bdd527c20b9d86a31cfc362d5426
INSTALL_DIR="${HOME}/meeting-pro-server"
PUBLIC_URL=''
ADVERTISE_IP=''
EMAIL=''
VOSK_IMAGE='alphacep/kaldi-ru:latest'
ACTION="${1:-help}"
[[ $# -eq 0 ]] || shift
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Jitsi + Jigasi + Vosk (русский), Linux / Docker Compose v2

  bash jitsi_install.sh configure --public-url https://meet.example.org \
    --advertise-ip 203.0.113.10 --email admin@example.org [--dir /path/to/new/install]
  bash jitsi_install.sh up     [--dir /path/to/install]
  bash jitsi_install.sh status [--dir /path/to/install]
  bash jitsi_install.sh logs   [--dir /path/to/install]
  bash jitsi_install.sh stop   [--dir /path/to/install]

configure создаёт конфигурацию; up запускает контейнеры.
Нужны DNS на сервер, доступные 80/tcp, 443/tcp, 10000/udp, Docker Compose v2.
Docker, firewall и существующие установки скрипт не изменяет.
Для другого языка: --vosk-image alphacep/kaldi-en:latest (или образ@sha256:...).
HELP
}
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || die "Нет значения для $1"
    case "$1" in
        --dir) INSTALL_DIR="$2" ;;
        --public-url) PUBLIC_URL="${2%/}" ;;
        --advertise-ip) ADVERTISE_IP="$2" ;;
        --email) EMAIL="$2" ;;
        --vosk-image) VOSK_IMAGE="$2" ;;
        *) die "Неизвестный параметр: $1" ;;
    esac
    shift 2
done
case "$ACTION" in help|--help|-h) usage; exit 0 ;; configure|up|status|logs|stop) ;; *) die "Неизвестная команда: $ACTION" ;; esac
[[ "$INSTALL_DIR" =~ ^/[a-zA-Z0-9_./-]+$ && "$INSTALL_DIR" != / ]] || die 'Каталог должен быть абсолютным путём без пробелов.'
command -v docker >/dev/null || die 'Установите Docker Engine: https://docs.docker.com/engine/install/'
docker compose version >/dev/null || die 'Установите Docker Compose v2.'

set_env() {
    local key="$1" value="$2" temp
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die 'Недопустимый перенос строки в настройке.'
    temp=$(mktemp "${INSTALL_DIR}/.env.XXXXXX")
    awk -v key="$key" '$0 !~ "^[#[:space:]]*" key "=" { print }' "$INSTALL_DIR/.env" > "$temp"
    printf '%s=%s\n' "$key" "$value" >> "$temp"
    mv -- "$temp" "$INSTALL_DIR/.env"
}
get_env() { sed -n "s/^$1=//p" "$INSTALL_DIR/.env" | head -n 1; }
compose() {
    local project
    project="meeting-pro-$(printf '%s' "$INSTALL_DIR" | cksum | awk '{print $1}')"
    docker compose --project-name "$project" --env-file "$INSTALL_DIR/.env" -f "$INSTALL_DIR/docker-compose.yml" -f "$INSTALL_DIR/transcriber.yml" -f "$INSTALL_DIR/meeting-pro.yml" "$@"
}

if [[ "$ACTION" == configure ]]; then
    [[ "$PUBLIC_URL" =~ ^https://([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || die 'Укажите HTTPS-домен без пути и порта.'
    [[ "$ADVERTISE_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die 'Укажите доступный участникам IPv4 сервера.'
    IFS=. read -r -a octets <<< "$ADVERTISE_IP"
    for octet in "${octets[@]}"; do ((10#$octet <= 255)) || die 'Некорректный IPv4.'; done
    [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || die 'Укажите email для сертификата TLS.'
    [[ "$VOSK_IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9./:@_-]*$ ]] || die 'Некорректное имя ASR-образа.'
    for tool in git openssl awk sed; do command -v "$tool" >/dev/null || die "Не найдена утилита $tool"; done
    if [[ -e "$INSTALL_DIR" ]]; then
        [[ -f "$INSTALL_DIR/.meeting-pro-managed" ]] || die 'Каталог уже существует и не управляется этим скриптом. Выберите новый --dir.'
        [[ "$(cat "$INSTALL_DIR/.meeting-pro-managed")" == "$VERSION" ]] || die 'Версия существующей установки отличается. Используйте отдельный каталог.'
        [[ "$(git -C "$INSTALL_DIR" rev-parse HEAD)" == "$UPSTREAM_COMMIT" ]] || die 'Изменена версия upstream. Используйте отдельный каталог.'
    else
        git clone --depth 1 --branch "$VERSION" https://github.com/jitsi/docker-jitsi-meet.git "$INSTALL_DIR"
        [[ "$(git -C "$INSTALL_DIR" rev-parse HEAD)" == "$UPSTREAM_COMMIT" ]] || die 'Контрольная версия upstream не совпала.'
        printf '%s\n' "$VERSION" > "$INSTALL_DIR/.meeting-pro-managed"
    fi
    if [[ -f "$INSTALL_DIR/.env" ]]; then
        cp -p -- "$INSTALL_DIR/.env" "$INSTALL_DIR/.env.backup.$(date +%Y%m%d%H%M%S).$$"
    else
        cp -- "$INSTALL_DIR/env.example" "$INSTALL_DIR/.env"
    fi
    for key in JICOFO_AUTH_PASSWORD JVB_AUTH_PASSWORD JIGASI_XMPP_PASSWORD JIGASI_TRANSCRIBER_PASSWORD JIBRI_RECORDER_PASSWORD JIBRI_XMPP_PASSWORD; do
        value=$(get_env "$key")
        if [[ -z "$value" || "$value" == passw0rd ]]; then set_env "$key" "$(openssl rand -hex 32)"; fi
    done
    set_env CONFIG "$INSTALL_DIR/config"
    set_env JITSI_IMAGE_VERSION "$VERSION"
    set_env PUBLIC_URL "$PUBLIC_URL"
    set_env JVB_ADVERTISE_IPS "$ADVERTISE_IP"
    set_env HTTP_PORT 80
    set_env HTTPS_PORT 443
    set_env ENABLE_HTTP_REDIRECT 1
    set_env ENABLE_LETSENCRYPT 1
    set_env LETSENCRYPT_DOMAIN "${PUBLIC_URL#https://}"
    set_env LETSENCRYPT_EMAIL "$EMAIL"
    set_env LETSENCRYPT_ACME_SERVER letsencrypt
    set_env ENABLE_JAAS_COMPONENTS 0
    set_env ENABLE_TRANSCRIPTIONS 1
    set_env JIGASI_TRANSCRIBER_CUSTOM_SERVICE org.jitsi.jigasi.transcription.VoskTranscriptionService
    set_env JIGASI_TRANSCRIBER_VOSK_URL ws://vosk:2700
    set_env JIGASI_TRANSCRIBER_ENABLE_SAVING true
    set_env JIGASI_TRANSCRIBER_RECORD_AUDIO false
    set_env JIGASI_TRANSCRIBER_SEND_TXT true
    set_env JIGASI_TRANSCRIBER_ADVERTISE_URL false
    set_env VOSK_IMAGE "$VOSK_IMAGE"
    mkdir -p "$INSTALL_DIR/config"/{web,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb,jigasi,jibri,transcriber}
    mkdir -p "$INSTALL_DIR/config"/storage/{jibri,prosody,transcripts,web} "$INSTALL_DIR/config"/tmp/{web-crontabs,web-load-test}
    mkdir -p "$INSTALL_DIR/config/web/nginx-custom"
    printf 'location ^~ /transcripts/ { return 403; }\n' > "$INSTALL_DIR/config/web/nginx-custom/meeting-pro-private-transcripts.conf"
    chmod 644 "$INSTALL_DIR/config/web/nginx-custom/meeting-pro-private-transcripts.conf"
    # Official rootless images use uid 1000. Only their writable storage is shared;
    # the parent installation directory remains private (umask 077).
    chmod 755 "$INSTALL_DIR/config" "$INSTALL_DIR/config/storage" "$INSTALL_DIR/config/tmp"
    chmod 755 "$INSTALL_DIR/config"/{web,web/nginx-custom,prosody,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb,jigasi,jibri,transcriber}
    chmod 777 "$INSTALL_DIR/config"/storage/{jibri,prosody,transcripts,web} "$INSTALL_DIR/config"/tmp/{web-crontabs,web-load-test}
    cat > "$INSTALL_DIR/meeting-pro.yml" <<'YAML'
services:
  transcriber:
    depends_on:
      vosk:
        condition: service_healthy
  vosk:
    image: ${VOSK_IMAGE:?Set VOSK_IMAGE}
    restart: unless-stopped
    networks:
      - meet.jitsi
    healthcheck:
      test: ["CMD", "python3", "-c", "import socket; socket.create_connection(('127.0.0.1',2700),5).close()"]
      interval: 10s
      timeout: 6s
      retries: 60
      start_period: 180s
YAML
    chmod 600 "$INSTALL_DIR/.env"
    compose config --quiet
    printf 'Конфигурация готова: %s\nЗапуск: bash %q up --dir %q\n' "$INSTALL_DIR" "$0" "$INSTALL_DIR"
    printf 'Перед публикацией настройте аутентификацию Jitsi (см. README). По умолчанию комнаты открытые.\n'
else
    [[ -f "$INSTALL_DIR/.meeting-pro-managed" && -f "$INSTALL_DIR/.env" ]] || die 'Сначала выполните configure.'
    case "$ACTION" in
        up) docker info >/dev/null; compose config --quiet; compose pull; compose up -d --wait --wait-timeout 900; compose ps ;;
        status) compose ps ;;
        logs) compose logs --tail=150 transcriber vosk ;;
        stop) compose stop ;;
    esac
fi
