#!/bin/bash

# Content-addressed GitHub downloader. The caller must pass a full commit SHA;
# branch names and tags are intentionally rejected.

require_unverified_installer_opt_in() {
    local dependency="$1"
    if [ "${MEKOPR_ALLOW_UNVERIFIED_INSTALLERS:-0}" != "1" ]; then
        echo "Установка $dependency заблокирована: upstream installer загружает вложенные артефакты без закреплённых SHA-256." >&2
        echo "Используйте проверяемый вариант из DEPLOYMENT_VPS.md. Осознанный временный opt-in: MEKOPR_ALLOW_UNVERIFIED_INSTALLERS=1." >&2
        return 1
    fi
    echo "ПРЕДУПРЕЖДЕНИЕ: разрешён неполностью проверяемый upstream installer: $dependency" >&2
}

secure_fetch_github_raw() {
    local repository="$1"
    local commit="$2"
    local source_path="$3"
    local destination="$4"

    if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        echo "Некорректное имя GitHub-репозитория: $repository" >&2
        return 1
    fi
    if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Зависимость $repository не закреплена на полном commit SHA" >&2
        return 1
    fi
    if [[ "$source_path" == /* || "$source_path" == *..* || "$source_path" == *$'\n'* ]]; then
        echo "Некорректный путь внешнего файла: $source_path" >&2
        return 1
    fi

    local destination_dir temporary_file
    destination_dir=$(dirname -- "$destination")
    install -d -m 0700 -- "$destination_dir"
    temporary_file=$(mktemp "${destination_dir}/.mekopr-download.XXXXXX") || return 1

    if ! curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
        --location --max-time 60 --retry 2 --retry-all-errors \
        "https://raw.githubusercontent.com/${repository}/${commit}/${source_path}" \
        --output "$temporary_file"; then
        rm -f -- "$temporary_file"
        return 1
    fi

    if [ ! -s "$temporary_file" ] || ! grep -Iq . "$temporary_file"; then
        echo "Загруженный файл пуст или не является текстовым скриптом" >&2
        rm -f -- "$temporary_file"
        return 1
    fi

    chown root:root "$temporary_file" 2>/dev/null || true
    chmod 0700 "$temporary_file"
    mv -f -- "$temporary_file" "$destination"
}

secure_run_github_script() {
    local interpreter="$1"
    local repository="$2"
    local commit="$3"
    local source_path="$4"
    shift 4

    case "$interpreter" in
        bash|sh) ;;
        *)
            echo "Недопустимый интерпретатор: $interpreter" >&2
            return 1
            ;;
    esac

    local temporary_dir script_file result
    temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/mekopr-fetch.XXXXXX") || return 1
    chmod 0700 "$temporary_dir"
    script_file="$temporary_dir/script.sh"

    if ! secure_fetch_github_raw "$repository" "$commit" "$source_path" "$script_file"; then
        rm -f -- "$script_file"
        rmdir -- "$temporary_dir" 2>/dev/null || true
        return 1
    fi

    "$interpreter" "$script_file" "$@"
    result=$?
    rm -f -- "$script_file"
    rmdir -- "$temporary_dir" 2>/dev/null || true
    return "$result"
}
