#!/bin/bash
set -Eeuo pipefail

# Устанавливает Docker Engine только из официального APT-репозитория.
# Скрипт предназначен для вызова установщиком Telemt и не добавляет обычных
# пользователей в root-equivalent группу docker.

DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

docker_install_log() { printf '  [i] %s\n' "$*"; }
docker_install_error() { printf '  [✗] %s\n' "$*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    docker_install_error "Установка Docker требует root"
    exit 1
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null
    docker info >/dev/null
    docker_install_log "Docker Engine и Compose уже готовы"
    exit 0
fi

if [ ! -r /etc/os-release ]; then
    docker_install_error "Не удалось определить операционную систему"
    exit 1
fi
# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
    ubuntu)
        docker_repo_os="ubuntu"
        docker_suite="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
        ;;
    debian)
        docker_repo_os="debian"
        docker_suite="${VERSION_CODENAME:-}"
        ;;
    *)
        docker_install_error "Автоматическая установка Docker поддерживает только Ubuntu и Debian"
        exit 1
        ;;
esac

if [ -z "$docker_suite" ] || [[ ! "$docker_suite" =~ ^[a-z0-9.-]+$ ]]; then
    docker_install_error "Не удалось безопасно определить codename дистрибутива"
    exit 1
fi

conflicting=()
for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed'; then
        conflicting+=("$package")
    fi
done
if [ "${#conflicting[@]}" -gt 0 ]; then
    docker_install_error "Обнаружены конфликтующие пакеты: ${conflicting[*]}"
    docker_install_error "Удалите их осознанно по официальной инструкции Docker и повторите установку"
    exit 1
fi

docker_install_log "Подключение официального APT-репозитория Docker (${docker_repo_os}/${docker_suite})"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg

install -d -m 0755 /etc/apt/keyrings
key_tmp=$(mktemp /tmp/docker-key.XXXXXX)
cleanup_key() {
    case "${key_tmp:-}" in
        /tmp/docker-key.*) rm -f -- "$key_tmp" ;;
    esac
}
trap cleanup_key EXIT

curl --proto '=https' --tlsv1.2 -fsSL \
    "https://download.docker.com/linux/${docker_repo_os}/gpg" \
    -o "$key_tmp"
actual_fingerprint=$(gpg --batch --show-keys --with-colons "$key_tmp" 2>/dev/null |
    awk -F: '$1 == "fpr" { print $10; exit }')
if [ "$actual_fingerprint" != "$DOCKER_GPG_FINGERPRINT" ]; then
    docker_install_error "Отпечаток ключа Docker не совпал с ожидаемым"
    exit 1
fi
install -o root -g root -m 0644 "$key_tmp" /etc/apt/keyrings/docker.asc

architecture=$(dpkg --print-architecture)
if [[ ! "$architecture" =~ ^[a-z0-9]+$ ]]; then
    docker_install_error "Некорректная архитектура APT: $architecture"
    exit 1
fi

sources_file=/etc/apt/sources.list.d/docker.sources
if [ -L "$sources_file" ]; then
    docker_install_error "$sources_file не должен быть символической ссылкой"
    exit 1
fi
cat >"$sources_file" <<EOF
Types: deb
URIs: https://download.docker.com/linux/${docker_repo_os}
Suites: ${docker_suite}
Components: stable
Architectures: ${architecture}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
chown root:root "$sources_file"
chmod 0644 "$sources_file"

apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

docker info >/dev/null
docker compose version >/dev/null
docker_install_log "Docker Engine и Docker Compose успешно установлены"
