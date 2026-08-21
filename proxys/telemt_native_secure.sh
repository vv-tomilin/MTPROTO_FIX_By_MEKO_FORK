#!/bin/bash
set -Eeuo pipefail

MEKOPR_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
DEPENDENCIES_FILE="$MEKOPR_ROOT/data/dependencies.env"
RULES_FILE="$MEKOPR_ROOT/data/rules.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "  ${BLUE}[i]${NC} $*"; }
log_ok() { echo -e "  ${GREEN}[✓]${NC} $*"; }
log_warn() { echo -e "  ${YELLOW}[!]${NC} $*"; }
log_error() { echo -e "  ${RED}[✗]${NC} $*" >&2; }
die() { log_error "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Установка требует root"
[ -r "$DEPENDENCIES_FILE" ] || die "Не найден lock-файл $DEPENDENCIES_FILE"
[ -r "$RULES_FILE" ] || die "Не найден файл правил $RULES_FILE"
# shellcheck disable=SC1090
source "$DEPENDENCIES_FILE"

for value in TELEMT_LOCKED_VERSION TELEMT_X86_64_GNU_SHA256 \
    TELEMT_X86_64_MUSL_SHA256 TELEMT_AARCH64_GNU_SHA256 TELEMT_AARCH64_MUSL_SHA256; do
    [ -n "${!value:-}" ] || die "В lock-файле отсутствует $value"
done

TEMP_DIR=""
INSTALL_COMPLETE=0
NATIVE_FILES_CREATED=0
cleanup() {
    code=$?
    if [ -n "$TEMP_DIR" ]; then
        case "$TEMP_DIR" in
            /tmp/telemt-native.*) rm -rf -- "$TEMP_DIR" ;;
        esac
    fi
    if [ "$code" -ne 0 ] && [ "$INSTALL_COMPLETE" -ne 1 ]; then
        if [ "$NATIVE_FILES_CREATED" -eq 1 ]; then
            systemctl disable --now telemt.service >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/telemt.service /usr/local/bin/telemt
            rm -rf /etc/telemt /var/lib/telemt
            rm -f /opt/mtpr-simple/config_path
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        echo ""
        log_error "TELEMT НЕ УСТАНОВЛЕН: обязательная проверка завершилась ошибкой"
    fi
}
trap cleanup EXIT

valid_ipv4() {
    local ip="$1" octet
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<<"$ip"
    for octet in "${octets[@]}"; do
        [ "$octet" -le 255 ] || return 1
    done
}

echo ""
echo -e "  ${BOLD}ПРОСТАЯ НАТИВНАЯ УСТАНОВКА TELEMT ${TELEMT_LOCKED_VERSION}${NC}"
echo -e "  ========================================================"
echo "  Будут автоматически установлены бинарник, systemd-служба"
echo "  и SYN-фильтр nftables. Архив проверяется по SHA-256."
echo ""

if systemctl is-active --quiet telemt.service 2>/dev/null || pgrep -x telemt >/dev/null 2>&1; then
    die "Telemt уже запущен. Для переустановки сначала используйте пункт удаления."
fi
if command -v docker >/dev/null 2>&1 && docker inspect telemt >/dev/null 2>&1; then
    die "Обнаружен контейнер telemt. Нельзя смешивать нативную и Docker-установку."
fi
if [ -e /etc/telemt/telemt.toml ] || [ -e /usr/local/bin/telemt ]; then
    die "Обнаружены файлы прежней нативной установки. Сначала удалите или сохраните их."
fi

read -rp "  Порт прокси [443]: " PORT
PORT=${PORT:-443}
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "Некорректный порт"

if command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :$PORT" 2>/dev/null | grep -q .; then
    die "Порт $PORT уже занят"
fi

read -rp "  TLS-домен [rutube.ru]: " TLS_DOMAIN
TLS_DOMAIN=${TLS_DOMAIN:-rutube.ru}
[[ "$TLS_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "Некорректный TLS-домен"
TLS_DOMAIN=${TLS_DOMAIN,,}

echo ""
echo "  Режим:       нативный systemd"
echo "  Версия:      $TELEMT_LOCKED_VERSION"
echo "  Порт:        $PORT"
echo "  TLS-домен:   $TLS_DOMAIN"
echo "  Секрет:      будет создан автоматически"
echo "  Firewall:    nftables INPUT, IPv4 + IPv6"
echo ""
read -rp "  Установить? [Y/n]: " CONFIRM
if [[ "${CONFIRM:-y}" =~ ^[Nn]$ ]]; then
    log_info "Установка отменена"
    exit 0
fi

for command_name in curl sha256sum tar openssl systemctl install useradd groupadd getent ldd od ss; do
    command -v "$command_name" >/dev/null 2>&1 || die "Не найдена обязательная команда: $command_name"
done

machine=$(uname -m)
case "$machine" in
    x86_64|amd64) asset_arch="x86_64" ;;
    aarch64|arm64) asset_arch="aarch64" ;;
    *) die "Архитектура $machine не поддерживается закреплёнными артефактами" ;;
esac
libc="gnu"
if ldd --version 2>&1 | grep -qi musl; then libc="musl"; fi
asset="telemt-${asset_arch}-linux-${libc}.tar.gz"
case "${asset_arch}_${libc}" in
    x86_64_gnu) expected_sha="$TELEMT_X86_64_GNU_SHA256" ;;
    x86_64_musl) expected_sha="$TELEMT_X86_64_MUSL_SHA256" ;;
    aarch64_gnu) expected_sha="$TELEMT_AARCH64_GNU_SHA256" ;;
    aarch64_musl) expected_sha="$TELEMT_AARCH64_MUSL_SHA256" ;;
    *) die "Нет checksum для ${asset_arch}/${libc}" ;;
esac
[[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || die "Некорректный SHA-256 в lock-файле"

TEMP_DIR=$(mktemp -d /tmp/telemt-native.XXXXXX)
archive="$TEMP_DIR/$asset"
url="https://github.com/telemt/telemt/releases/download/${TELEMT_LOCKED_VERSION}/${asset}"
log_info "Скачивание закреплённого архива $asset"
curl --proto '=https' --tlsv1.2 -fL --retry 3 --connect-timeout 10 -o "$archive" "$url"
printf '%s  %s\n' "$expected_sha" "$archive" | sha256sum -c - >/dev/null || die "SHA-256 архива Telemt не совпал"
log_ok "SHA-256 архива подтверждён"

entry_count=0
while IFS= read -r entry; do
    case "$entry" in
        telemt|./telemt|./) ;;
        *) die "В архиве обнаружен неожиданный путь: $entry" ;;
    esac
    case "$entry" in telemt|./telemt) entry_count=$((entry_count + 1)) ;; esac
done < <(tar -tzf "$archive")
[ "$entry_count" -eq 1 ] || die "Архив должен содержать ровно один бинарник telemt"
tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$TEMP_DIR"
binary="$TEMP_DIR/telemt"
[ -f "$binary" ] || binary="$TEMP_DIR/./telemt"
[ -f "$binary" ] || die "Бинарник telemt не найден после распаковки"
chmod 0755 "$binary"
"$binary" --version >/dev/null 2>&1 || die "Загруженный бинарник не запускается"

SECRET=$(openssl rand -hex 16)
[ "${#SECRET}" -eq 32 ] || die "Не удалось создать секрет"
SERVER_IP=$(curl --proto '=https' --tlsv1.2 -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
valid_ipv4 "$SERVER_IP" || die "Не удалось определить публичный IPv4"

getent group telemt >/dev/null 2>&1 || groupadd --system telemt
if ! getent passwd telemt >/dev/null 2>&1; then
    nologin_shell=$(command -v nologin 2>/dev/null || command -v false 2>/dev/null || true)
    [ -n "$nologin_shell" ] || die "Не найден системный nologin/false shell"
    useradd --system --gid telemt --home-dir /var/lib/telemt --shell "$nologin_shell" telemt
fi
NATIVE_FILES_CREATED=1
install -d -o telemt -g telemt -m 0750 /var/lib/telemt /var/lib/telemt/tlsfront
install -d -o root -g telemt -m 0750 /etc/telemt
install -o root -g root -m 0755 "$binary" /usr/local/bin/telemt

config_tmp="$TEMP_DIR/telemt.toml"
cat >"$config_tmp" <<EOF
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "$SERVER_IP"
public_port = $PORT

[server]
port = $PORT

[server.api]
enabled = false

[censorship]
tls_domain = "$TLS_DOMAIN"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
myuser = "$SECRET"
EOF
install -o root -g telemt -m 0640 "$config_tmp" /etc/telemt/telemt.toml

unit_tmp="$TEMP_DIR/telemt.service"
cat >"$unit_tmp" <<'EOF'
[Unit]
Description=Telemt MTProto Proxy (verified native installation)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/var/lib/telemt
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/telemt
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF
install -o root -g root -m 0644 "$unit_tmp" /etc/systemd/system/telemt.service
echo /etc/telemt/telemt.toml >/opt/mtpr-simple/config_path
chown root:root /opt/mtpr-simple/config_path
chmod 0600 /opt/mtpr-simple/config_path

systemctl daemon-reload
systemctl enable --now telemt.service
for _ in 1 2 3 4 5 6 7 8 9 10; do
    systemctl is-active --quiet telemt.service && \
        ss -H -ltn "sport = :$PORT" 2>/dev/null | grep -q . && break
    sleep 1
done
if ! systemctl is-active --quiet telemt.service || \
   ! ss -H -ltn "sport = :$PORT" 2>/dev/null | grep -q .; then
    journalctl -u telemt.service -n 30 --no-pager >&2 || true
    systemctl disable --now telemt.service >/dev/null 2>&1 || true
    die "Telemt не прошёл проверку службы/порта"
fi
log_ok "Telemt запущен и слушает порт $PORT"

# Удаляем только ранее созданные проектом SYN FIX и ставим корректный backend
# для нативного процесса (nftables hook INPUT).
# shellcheck disable=SC1090
source "$RULES_FILE"
remove_syn_fix >/dev/null 2>&1 || true
if ! install_syn_fix -auto_install -port "$PORT" -type nft; then
    systemctl disable --now telemt.service >/dev/null 2>&1 || true
    remove_syn_fix >/dev/null 2>&1 || true
    die "Не удалось установить обязательный nftables SYN FIX; Telemt остановлен"
fi
if ! systemctl is-active --quiet mtpr-nft-synfix.service || \
   ! nft list table inet mtpr_synfix >/dev/null 2>&1; then
    systemctl disable --now telemt.service >/dev/null 2>&1 || true
    remove_syn_fix >/dev/null 2>&1 || true
    die "SYN FIX не прошёл итоговую проверку; Telemt остановлен"
fi

HEX_DOMAIN=$(printf '%s' "$TLS_DOMAIN" | od -An -tx1 | tr -d ' \n')
LINK="tg://proxy?server=${SERVER_IP}&port=${PORT}&secret=ee${SECRET}${HEX_DOMAIN}"
INSTALL_COMPLETE=1
echo ""
echo -e "  ${GREEN}${BOLD}========================================================${NC}"
echo -e "  ${GREEN}${BOLD} TELEMT УСТАНОВЛЕН: НАТИВНЫЙ + NFTABLES SYN FIX${NC}"
echo -e "  ${GREEN}${BOLD}========================================================${NC}"
echo "  Служба:  active"
echo "  Порт:    $PORT/tcp слушается"
echo "  Firewall: mtpr-nft-synfix active"
echo ""
echo -e "  ${CYAN}${LINK}${NC}"
echo ""
