#!/bin/bash
# telemt_in_docker1.sh - Установка Telemt в Docker

MEKOPR_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
if [ ! -r "$MEKOPR_ROOT/data/dependencies.env" ]; then
    echo "Не найден lock-файл зависимостей MEKOpr" >&2
    return 1 2>/dev/null || exit 1
fi
# shellcheck disable=SC1091
source "$MEKOPR_ROOT/data/dependencies.env"

# ── Цвета ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Функции логирования ─────────────────────────────────────
log_info() { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "  ${RED}[✗]${NC} $1" >&2; }
log_warning() { echo -e "  ${YELLOW}[!]${NC} $1"; }

# ── Проверка root ────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    log_error "Требуются права root"
    exit 1
fi

# Образ закреплён по OCI digest: обновление выполняется только после аудита
# новой версии и явной замены digest в репозитории.
TELEMT_VERSION="$TELEMT_LOCKED_VERSION"
if [[ ! "$TELEMT_IMAGE" =~ ^ghcr\.io/telemt/telemt@sha256:[0-9a-f]{64}$ ]]; then
    log_error "Образ Telemt не закреплён корректным OCI digest"
    return 1 2>/dev/null || exit 1
fi

# ── Проверка Docker ──────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log_error "Docker не установлен. Установите Docker Engine из официального репозитория ОС и повторите запуск."
    return 1 2>/dev/null || exit 1
fi

# ── Заголовок ─────────────────────────────────────────────────
clear
echo ""
echo -e "  ${BOLD}УСТАНОВКА TELEMT В DOCKER v0.2${NC}"
echo -e "  ${DIM}================================${NC}"
echo ""
echo -e "  Будет установлен Telemt ${GREEN}${TELEMT_VERSION}${NC} в Docker контейнере"
echo -e "  ${DIM}Версия: ${TELEMT_VERSION}${NC}"
echo ""
echo -en "  ${BOLD}Продолжить установку? Y/n:${NC} "
read -r confirm
if [[ -n "$confirm" && "$confirm" =~ ^[nN]$ ]]; then
    log_info "Установка отменена"
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
    read -rsn1
    return 0 2>/dev/null || exit 0
fi

# ── 1) Автозапуск Docker ─────────────────────────────────────
echo ""
echo -e "  ${BOLD}1. Включить автозапуск Docker при старте системы?${NC}"
echo -e "  ${DIM}(systemctl enable docker && systemctl start docker)${NC}"
echo -en "  ${BOLD}Включить? Y/n:${NC} "
read -r docker_autostart
if [[ -z "$docker_autostart" || "$docker_autostart" =~ ^[yY]$ ]]; then
    log_info "Включение автозапуска Docker..."
    systemctl enable docker 2>/dev/null && systemctl start docker 2>/dev/null
    log_success "Docker автозапуск включён"
else
    log_info "Автозапуск Docker пропущен"
fi

# ── 2) Путь установки ────────────────────────────────────────
echo ""
echo -e "  ${BOLD}2. Путь установки Telemt${NC}"
echo -e "  ${DIM}По умолчанию: /root/telemt${NC}"
echo -en "  ${BOLD}Введите путь или нажмите Enter для выбора стандартного:${NC} "
read -r install_path
if [ -z "$install_path" ]; then
    install_path="/root/telemt"
fi
if [[ "$install_path" == *$'\n'* ]] || [[ "$install_path" == *'/../'* ]] || [[ "$install_path" == *'/..' ]]; then
    log_error "Путь установки содержит небезопасные компоненты"
    return 1 2>/dev/null || exit 1
fi
case "$install_path" in
    /root/*|/opt/*) ;;
    *)
        log_error "Путь установки должен быть отдельным каталогом внутри /root или /opt"
        return 1 2>/dev/null || exit 1
        ;;
esac
resolved_install_path=$(realpath -m -- "$install_path") || {
    log_error "Не удалось разрешить путь установки"
    return 1 2>/dev/null || exit 1
}
case "$resolved_install_path" in
    /root/*|/opt/*) install_path="$resolved_install_path" ;;
    *)
        log_error "Разрешённый путь выходит за пределы /root или /opt"
        return 1 2>/dev/null || exit 1
        ;;
esac
if [ -L "$install_path" ]; then
    log_error "Путь установки не должен быть символической ссылкой"
    return 1 2>/dev/null || exit 1
fi
if [ -e "$install_path/config.toml" ] || [ -e "$install_path/docker-compose.yml" ]; then
    log_error "В каталоге уже есть конфигурация. Сначала сделайте резервную копию и удалите старую установку."
    return 1 2>/dev/null || exit 1
fi
log_info "Путь: $install_path"

# ── 3) Порт ───────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}3. Порт для прокси${NC}"
echo -e "  ${DIM}По умолчанию: 443${NC}"
echo -en "  ${BOLD}Введите порт или нажмите Enter для выбора порта поумолчанию:${NC} "
read -r port_input
if [ -z "$port_input" ]; then
    port="443"
elif [[ "$port_input" =~ ^[0-9]+$ ]] && [ "$port_input" -ge 1 ] && [ "$port_input" -le 65535 ]; then
    port="$port_input"
else
    log_warning "Некорректный порт, используем 443"
    port="443"
fi
echo -e "  ${GREEN}✓${NC} Использован порт: ${CYAN}${port}${NC}"

# ── 4) Секрет (с циклом) ─────────────────────────────────────
echo ""
echo -e "  ${BOLD}4. Секрет для доступа к прокси${NC}"

SECRET=""
while true; do
    # Генерируем секрет при первом проходе или при gen
    if [ -z "$SECRET" ]; then
        SECRET=$(openssl rand -hex 16)
    fi
    
    echo -e "  ${DIM}Сгенерирован секрет: ${CYAN}${SECRET}${NC}"
    echo ""
    echo -e "  ${BOLD}Варианты:${NC}"
    echo -e "  ${GREEN}Enter/Y${NC} — использовать сгенерированный секрет"
    echo -e "  ${CYAN}Ввести вручную${NC} — указать свой секрет"
    echo -e "  ${RED}gen${NC} — перегенерировать новый секрет"
    echo ""
    echo -en "  ${BOLD}Ваш выбор:${NC} "
    read -r secret_input
    
    if [[ "$secret_input" =~ ^[Gg][Ee][Nn]$ ]]; then
        SECRET=$(openssl rand -hex 16)
        echo ""
        echo -e "  ${GREEN}✓${NC} Новый секрет: ${CYAN}${SECRET}${NC}"
        echo ""
        # Показываем меню снова с новым секретом
        continue
    elif [[ -n "$secret_input" ]] && [[ ! "$secret_input" =~ ^[yY]$ ]]; then
        if [[ ! "$secret_input" =~ ^[0-9a-fA-F]{32}$ ]]; then
            log_warning "Секрет должен содержать ровно 32 шестнадцатеричных символа"
            continue
        fi
        SECRET="${secret_input,,}"
        echo ""
        echo -e "  ${GREEN}✓${NC} Использован секрет: ${CYAN}${SECRET}${NC}"
        echo ""
        break
    else
        # Enter или y/Y
        echo ""
        echo -e "  ${GREEN}✓${NC} Использован сгенерированный секрет: ${CYAN}${SECRET}${NC}"
        echo ""
        break
    fi
done

# ── 5) TLS домен ─────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}5. TLS домен для маскировки${NC}"
echo -e "  ${DIM}По умолчанию: rutube.ru${NC}"
echo -en "  ${BOLD}Введите домен или нажмите Enter для выбора rutube.ru:${NC} "
read -r tls_domain_input
if [ -z "$tls_domain_input" ]; then
    tls_domain="rutube.ru"
elif [[ "$tls_domain_input" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$tls_domain_input" != .* ]] && [[ "$tls_domain_input" != *. ]]; then
    tls_domain="${tls_domain_input,,}"
else
    log_error "Некорректное доменное имя"
    return 1 2>/dev/null || exit 1
fi
echo -e "  ${GREEN}✓${NC} Использован домен: ${CYAN}${tls_domain}${NC}"

# ── 6) Определяем IP ─────────────────────────────────────────
SERVER_IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
if [[ ! "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    log_error "Не удалось безопасно определить публичный IPv4-адрес"
    return 1 2>/dev/null || exit 1
fi
echo ""
log_info "Обнаружен IP: $SERVER_IP"

# ── 7) Установка ─────────────────────────────────────────────
echo ""
log_info "Начинаем установку Telemt ${TELEMT_VERSION} в Docker..."
echo ""

# Создаем папку с закрытыми правами
umask 077
install -d -m 0700 -- "$install_path"
cd "$install_path" || { return 1 2>/dev/null || exit 1; }
log_success "Папка создана: $install_path"

# Полное значение заголовка Authorization. Оно хранится только в root-only
# config.toml и не выводится в терминал.
API_AUTH="Bearer $(openssl rand -hex 32)"

# Создаем config.toml
cat > config.toml <<EOF
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
public_port = $port

[server]
port = $port

[server.api]
enabled = true
listen = "0.0.0.0:9091"
whitelist = ["127.0.0.0/8", "172.16.0.0/12"]
auth_header = "$API_AUTH"
read_only = true
request_body_limit_bytes = 16384

[censorship]
tls_domain = "$tls_domain"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
myuser = "$SECRET"
EOF
chmod 0600 config.toml
log_success "config.toml создан"

# Создаем docker-compose.yml
cat > docker-compose.yml <<EOF
services:
  telemt:
    image: ${TELEMT_IMAGE}
    container_name: telemt
    restart: unless-stopped
    ports:
      - "${port}:${port}"
      - "127.0.0.1:9091:9091"
    volumes:
      - ./config.toml:/app/config.toml:ro
      - ./tlsfront:/app/tlsfront:rw
    environment:
      - RUST_LOG=info
    cap_add:
      - NET_BIND_SERVICE
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=64m
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    security_opt:
      - no-new-privileges:true
    pids_limit: 256
EOF
chmod 0600 docker-compose.yml
log_success "docker-compose.yml создан"

# jq нужен только для удобного вывода ссылки после запуска.
if ! command -v jq >/dev/null 2>&1; then
    log_warning "jq не установлен; ссылка будет доступна в конфиге/API"
fi

# Запускаем
log_info "Запуск Docker контейнера..."
if docker compose up -d; then
    log_success "Telemt успешно запущен"
else
    log_error "Ошибка запуска Telemt"
    return 1 2>/dev/null || exit 1
fi

# ── 8) Вывод ссылки ──────────────────────────────────────────
echo ""
echo -e "  ${BOLD}${GREEN}═════════════════════════════════════════════════${NC}"
echo -e "  ${BOLD}${GREEN}        TELEMT УСТАНОВЛЕН УСПЕШНО!${NC}"
echo -e "  ${BOLD}${GREEN}═════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}ССЫЛКА ДЛЯ ПОДКЛЮЧЕНИЯ В TELEGRAM:${NC}"
echo ""

sleep 1

# Пробуем получить ссылку
LINK=""
if command -v jq >/dev/null 2>&1; then
    LINK=$(curl -fsS --max-time 5 -H "Authorization: $API_AUTH" http://127.0.0.1:9091/v1/users 2>/dev/null | jq -r '.data[].links.tls[]' 2>/dev/null | grep -v "::" | grep -v "0.0.0.0" | head -1)
fi
if [ -n "$LINK" ]; then
    echo -e "  ${CYAN}${LINK}${NC}"
else
    echo -e "  ${YELLOW}Ссылка пока не доступна. Попробуйте позже:${NC}"
    echo -e "  ${DIM}  docker compose logs -f${NC}"
    echo -e "  ${DIM}  Проверьте состояние: docker compose logs --tail=100 telemt${NC}"
fi

echo ""
echo -e "  ${BOLD}Данные для подключения:${NC}"
echo -e "  ${BOLD}Версия:${NC} ${CYAN}${TELEMT_VERSION}${NC}"
echo -e "  ${BOLD}Секрет:${NC} ${CYAN}${SECRET}${NC}"
echo -e "  ${BOLD}IP сервера:${NC} ${CYAN}${SERVER_IP}${NC}"
echo -e "  ${BOLD}Порт:${NC} ${CYAN}${port}${NC}"
echo -e "  ${BOLD}TLS домен:${NC} ${CYAN}${tls_domain}${NC}"
echo -e "  ${BOLD}API:${NC} ${GREEN}только 127.0.0.1, read-only, с Authorization${NC}"
echo ""
echo -e "  ${BOLD}Команды управления:${NC}"
echo -e "  ${DIM}  docker compose logs -f  # просмотр логов${NC}"
echo -e "  ${DIM}  docker compose restart  # перезапуск${NC}"
echo -e "  ${DIM}  docker compose down     # остановка${NC}"
echo -e "  ${DIM}  docker compose up -d    # запуск после остановки${NC}"
echo -e "  ${BOLD}${GREEN}═════════════════════════════════════════════════${NC}"
echo ""

echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
read -rsn1
return 0 2>/dev/null || exit 0
