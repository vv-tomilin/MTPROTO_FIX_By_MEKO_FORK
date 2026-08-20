#!/bin/bash
set -euo pipefail

# Безопасная установка выполняется только из локального checkout. Скрипт
# намеренно не загружает собственное содержимое из изменяемой ветки main.

INSTALL_DIR="/opt/mtpr-simple"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
MANIFEST_FILE="$SCRIPT_DIR/data/manifest.txt"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[✗]${NC} Запустите локальный файл через sudo: ${BOLD}sudo ./install_main.sh${NC}" >&2
    exit 1
fi

if [ ! -r "$MANIFEST_FILE" ] || [ ! -r "$SCRIPT_DIR/main.sh" ]; then
    echo -e "${RED}[✗]${NC} Не найден полный локальный checkout проекта." >&2
    echo "Клонируйте репозиторий, проверьте commit и запустите install_main.sh из его корня." >&2
    exit 1
fi

if [ -L "$INSTALL_DIR" ]; then
    echo -e "${RED}[✗]${NC} $INSTALL_DIR не должен быть символической ссылкой" >&2
    exit 1
fi

STAGING_DIR=$(mktemp -d "/opt/mtpr-simple.new.XXXXXX")
chmod 0700 "$STAGING_DIR"
BACKUP_DIR=""

cleanup_staging() {
    case "${STAGING_DIR:-}" in
        /opt/mtpr-simple.new.*)
            if [ -d "$STAGING_DIR" ]; then
                rm -rf -- "$STAGING_DIR"
            fi
            ;;
    esac
    if [ -n "${BACKUP_DIR:-}" ] && [ -d "$BACKUP_DIR" ] && [ ! -e "$INSTALL_DIR" ]; then
        mv -- "$BACKUP_DIR" "$INSTALL_DIR" || true
    fi
}
trap cleanup_staging EXIT INT TERM

echo -e "${BLUE}[i]${NC} Установка из локального checkout: $SCRIPT_DIR"

installed_count=0
while IFS='|' read -r file_path description; do
    file_path=$(printf '%s' "$file_path" | xargs)
    [[ -z "$file_path" || "$file_path" == \#* ]] && continue

    if [[ "$file_path" == /* || "$file_path" == *..* || ! "$file_path" =~ ^[A-Za-z0-9_./-]+$ ]]; then
        echo -e "${RED}[✗]${NC} Небезопасный путь в manifest: $file_path" >&2
        exit 1
    fi

    source_file="$SCRIPT_DIR/$file_path"
    destination_file="$STAGING_DIR/$file_path"
    if [ ! -f "$source_file" ] || [ -L "$source_file" ]; then
        echo -e "${RED}[✗]${NC} Отсутствует обычный файл: $file_path" >&2
        exit 1
    fi

    mode=0644
    case "$file_path" in
        *.sh|*.py) mode=0755 ;;
    esac
    install -D -o root -g root -m "$mode" -- "$source_file" "$destination_file"
    installed_count=$((installed_count + 1))
done < "$MANIFEST_FILE"

if [ ! -x "$STAGING_DIR/main.sh" ] || [ "$installed_count" -lt 5 ]; then
    echo -e "${RED}[✗]${NC} Staging-проверка не пройдена" >&2
    exit 1
fi

if [ -d "$INSTALL_DIR" ]; then
    BACKUP_DIR="${INSTALL_DIR}.backup.$(date -u +%Y%m%d%H%M%S)"
    mv -- "$INSTALL_DIR" "$BACKUP_DIR"
fi

if ! mv -- "$STAGING_DIR" "$INSTALL_DIR"; then
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        mv -- "$BACKUP_DIR" "$INSTALL_DIR"
    fi
    exit 1
fi
STAGING_DIR=""

ln -sfn "$INSTALL_DIR/main.sh" /usr/local/bin/mekopr

echo -e "${GREEN}[✓]${NC} Установлено файлов: $installed_count"
echo -e "${GREEN}[✓]${NC} Команда управления: ${BOLD}sudo mekopr${NC}"
if [ -n "$BACKUP_DIR" ]; then
    echo -e "${YELLOW}[i]${NC} Предыдущая версия сохранена: $BACKUP_DIR"
fi

if [ -r /dev/tty ]; then
    exec "$INSTALL_DIR/main.sh" </dev/tty
fi
