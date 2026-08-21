# Безопасное развёртывание MEKOpr на VPS

Эта инструкция описывает рекомендуемый вариант для отдельного VPS. Не устанавливайте проект на сервер с базами данных, корпоративными ключами, почтой или другими ценными сервисами.

Этот код — неофициальный hardening-fork проекта [MTPROTO_FIX_By_MEKO](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO), а не официальный релиз MEKO. Сохраняйте `LICENSE` и `NOTICE.md`, не удаляйте upstream-атрибуцию и указывайте собственный репозиторий как источник защищённой версии.

## 0. Публикация собственного hardening-репозитория

Перед развёртыванием создайте новый пустой репозиторий под нейтральным названием, которое не подразумевает официальный релиз MEKO. Затем настройте remotes:

```bash
git remote rename origin upstream
read -rp "URL вашего пустого GitHub-репозитория: " HARDENED_REPO_URL
case "$HARDENED_REPO_URL" in
    https://github.com/*/*.git) ;;
    *) echo "Ожидается HTTPS URL GitHub с окончанием .git" >&2; exit 1 ;;
esac
git remote add origin "$HARDENED_REPO_URL"
git checkout -b security-hardening
git add --all
git commit -m "Security hardening of unofficial upstream fork"
git push -u origin security-hardening
```

После публикации сохраните полученный `git rev-parse HEAD` как SHA защищённого релиза. Не используйте исходный `0c3abf1...`: он относится к состоянию до исправлений.

Если через этот код предоставляется публичная сетевая услуга, добавьте в описание услуги, документацию или страницу «О сервисе» видимую атрибуцию без намёка на одобрение, например:

```text
Основано на неофициально модифицированном MTPROTO_FIX_By_MEKO.
Оригинал: https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO
Данный сервис не одобрен и не поддерживается MEKO.
```

## 1. Рекомендуемая схема

- отдельный VPS с Ubuntu 24.04 LTS или Debian 12;
- один публичный proxy-порт, обычно `443/tcp`;
- SSH доступен только с административного IP или через VPN;
- Telemt API публикуется только на `127.0.0.1:9091`;
- административная панель публикуется только на `127.0.0.1:8080`;
- автоматические root-обновления и Watchtower не используются;
- репозиторий и все зависимости закреплены на проверенных commit SHA/digest.

## 2. Подготовка cloud firewall

До первого подключения настройте firewall/security group в панели VPS-провайдера.

Разрешите:

| Порт | Источник | Назначение |
|---|---|---|
| `22/tcp` или ваш SSH-порт | Только административный IP/VPN | Управление сервером |
| `443/tcp` или выбранный proxy-порт | `0.0.0.0/0` и `::/0`, если нужен IPv6 | MTProto proxy |

Не открывайте наружу:

- `9091/tcp` — Telemt API;
- `8080/tcp` — Telemt Panel;
- Docker daemon `2375/2376`;
- любые отладочные и внутренние порты.

## 3. Базовая подготовка VPS

Подключитесь по SSH и обновите систему:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y git curl ca-certificates openssl nftables python3
sudo reboot
```

После перезагрузки проверьте время:

```bash
timedatectl status
```

Для SSH рекомендуется отдельный пользователь с ключом, запрет парольной аутентификации и запрет прямого входа `root`. Перед изменением `sshd` обязательно сохраните открытой вторую административную сессию.

## 4. Получение проверенного исходного кода

Не используйте `curl | sudo bash`.

```bash
read -rp "URL вашего hardening-репозитория: " HARDENED_REPO_URL
case "$HARDENED_REPO_URL" in
    https://github.com/*/*.git) ;;
    *) echo "Ожидается HTTPS URL GitHub с окончанием .git" >&2; exit 1 ;;
esac
git clone -- "$HARDENED_REPO_URL" hardened-mtproto-proxy
cd hardened-mtproto-proxy
git fetch --tags --prune
read -rp "40-символьный SHA проверенного защищённого релиза: " AUDITED_COMMIT
[[ "$AUDITED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "Некорректный SHA" >&2; exit 1; }
git checkout --detach "$AUDITED_COMMIT"
git status --short
git rev-parse HEAD
```

`git status --short` не должен выводить изменённые или неизвестные файлы. Значение `git rev-parse HEAD` должно совпадать с SHA, который вы проверили до установки.

В текущей hardening-версии список внешних зависимостей находится в [`data/dependencies.env`](data/dependencies.env). Перед развёртыванием проверьте, что там используются полные 40-символьные commit SHA и OCI digest вида `sha256:...`.

## 5. Установка MEKO Launcher

Из корня локального checkout выполните:

```bash
sudo ./install_main.sh
```

Установщик:

- не скачивает собственные файлы из ветки `main`;
- копирует локальный проверенный checkout через staging-каталог;
- назначает владельца `root:root`;
- сохраняет предыдущую установку в `/opt/mtpr-simple.backup.<дата>`;
- создаёт команду `/usr/local/bin/mekopr`.

Открыть меню повторно:

```bash
sudo mekopr
```

## 6. Docker-вариант Telemt

Сначала установите Docker Engine из официального репозитория Docker для вашей ОС. Не используйте `get.docker.com | sh`. Инструкция: <https://docs.docker.com/engine/install/>.

Docker предупреждает, что опубликованные порты контейнеров могут обходить UFW, а
пользовательские правила для Docker следует размещать в цепочке `DOCKER-USER`.
Поэтому варианты SYN FIX на чистом `nftables` предназначены только для нативного
proxy-процесса. Для Docker сначала установите и запустите Docker, затем Telemt,
после чего используйте hardening-вариант `iptables`: он подключает проектную
цепочку одновременно к `INPUT` и `DOCKER-USER`. Если `xt_u32` недоступен,
используйте вариант `iptables` без u32.

Проверьте установку:

```bash
docker --version
docker compose version
sudo systemctl enable --now docker
```

Запустите:

```bash
sudo /opt/mtpr-simple/proxys/telemt_in_docker1.sh
```

Безопасные свойства создаваемой конфигурации:

- образ Telemt закреплён по OCI digest;
- Watchtower отсутствует;
- API опубликован как `127.0.0.1:9091:9091`;
- для API создаётся случайный `Authorization` token;
- API работает в `read_only`;
- `config.toml` и `docker-compose.yml` имеют права `0600`;
- контейнер использует `cap_drop: ALL` и `no-new-privileges`.
- root filesystem контейнера работает в режиме `read_only`, временные файлы — в отдельном `tmpfs`.

Стандартные installer-скрипты Telemt, mtproto.zig, 3x-ui, Remnawave, MTProxyL и Telemt Panel закреплены по commit SHA, но их вложенные release-артефакты не имеют закреплённых в этом проекте checksums. Поэтому они заблокированы по умолчанию. Переменная `MEKOPR_ALLOW_UNVERIFIED_INSTALLERS=1` существует только как осознанный аварийный opt-in и не рекомендуется для production. Для Telemt используйте описанный выше Docker-образ по digest; для MTG — проверяемый установщик из раздела 9.

## 7. Проверка после запуска

### Контейнер и образ

```bash
cd /root/telemt
sudo docker compose ps
sudo docker inspect telemt --format '{{.Config.Image}}'
sudo docker ps --format '{{.Names}}' | grep -x watchtower && echo 'ОШИБКА: Watchtower не должен быть запущен'
```

### Слушающие порты

```bash
sudo ss -lntp
```

Ожидается:

- proxy-порт слушает публичный адрес;
- `9091` слушает только `127.0.0.1`;
- `8080` отсутствует либо слушает только `127.0.0.1`;
- Docker daemon не слушает публичный TCP-порт.

Проверка с другой машины:

```bash
VPS_IP="203.0.113.10"
nmap -Pn -p 22,443,8080,9091 "$VPS_IP"
```

Снаружи должны быть доступны только разрешённый SSH-порт и proxy-порт.

### Права на секреты

```bash
sudo stat -c '%U:%G %a %n' /root/telemt/config.toml /root/telemt/docker-compose.yml
```

Ожидаемые права: `root:root 600`.

### Firewall

```bash
sudo nft list ruleset
command -v iptables-save >/dev/null && sudo iptables-save
command -v ip6tables-save >/dev/null && sudo ip6tables-save
sudo iptables -S DOCKER-USER | grep MTPR_SYNFIX
```

Для Docker последняя команда должна показать переход в `MTPR_SYNFIX`. Одного
перехода из `INPUT` недостаточно: опубликованный контейнерный порт проходит по
пути `FORWARD`/`DOCKER-USER`.

Не должно быть безусловного правила вида:

```text
-A INPUT -p tcp --dport 22 -j ACCEPT
```

если SSH должен быть ограничен административным адресом.

Старое правило нельзя безопасно отличить от правила, созданного администратором, поэтому hardening не удаляет его автоматически. Проверяйте его из второй открытой SSH-сессии. Только убедившись, что cloud firewall/UFW разрешают ваш административный адрес, удалите точное лишнее правило, например:

```bash
SSH_PORT="22"
sudo iptables -C INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
sudo iptables -D INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
```

## 8. Доступ к Telemt Panel

Панель после hardening слушает только loopback. Для доступа используйте SSH tunnel с рабочего компьютера:

```bash
VPS_IP="203.0.113.10"
ssh -L 8080:127.0.0.1:8080 "admin@$VPS_IP"
```

После подключения откройте:

```text
http://127.0.0.1:8080
```

Для постоянного многопользовательского доступа используйте HTTPS reverse proxy с современным TLS и дополнительной аутентификацией. Не меняйте `listen` панели обратно на `0.0.0.0`.

## 9. MTG

MTG устанавливается в закреплённой версии. Перед распаковкой проверяются официальный список SHA-256 и checksum выбранного архива.

Служба запускается от отдельного пользователя `mtg`, а конфигурация должна иметь права:

```bash
sudo stat -c '%U:%G %a %n' /etc/mtg.toml
```

Ожидается:

```text
root:mtg 640 /etc/mtg.toml
```

Проверка sandboxing:

```bash
sudo systemd-analyze security mtg.service
```

## 10. Безопасное обновление

Сетевое самообновление MEKOpr отключено. Обновляйте через отдельный checkout:

```bash
cd MTPROTO_FIX_By_MEKO
git fetch --tags --prune
read -rp "Текущий 40-символьный SHA: " CURRENT_SHA
read -rp "Новый проверенный 40-символьный SHA: " NEW_AUDITED_COMMIT
[[ "$CURRENT_SHA" =~ ^[0-9a-f]{40}$ && "$NEW_AUDITED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || exit 1
git diff "$CURRENT_SHA..$NEW_AUDITED_COMMIT"
git checkout --detach "$NEW_AUDITED_COMMIT"
sudo ./install_main.sh
```

При обновлении внешней зависимости:

1. изучите changelog и diff upstream;
2. замените commit SHA или image digest в `data/dependencies.env`;
3. проверьте URL и checksum release-артефактов;
4. протестируйте на отдельном VPS;
5. только после этого обновляйте production VPS.

Не заменяйте commit SHA обратно на `main`, `master`, `latest` или плавающий Docker tag.

## 11. Ротация секретов

Смените proxy secret и административные пароли:

- после любого подозрения на публикацию `9091` или `8080`;
- после попадания ссылки в публичный лог/чат;
- при удалении администратора;
- после восстановления сервера из недоверенной резервной копии.

Proxy secret даёт возможность использовать прокси, поэтому полную `tg://proxy`-ссылку следует хранить как секрет. Не передавайте секреты через аргументы командной строки и CI-логи.

## 12. Удаление и проверка очистки

Используйте пункт полного удаления в `sudo mekopr`, затем проверьте:

```bash
sudo systemctl list-unit-files | grep -E 'mtpr|zapret|telemt|mtg'
sudo nft list ruleset
sudo iptables-save
sudo ip6tables-save
sudo ss -lntp
```

Особенно проверьте отсутствие:

- `mtpr-zapret2.service`;
- `mtpr-zapret2-watch.service`;
- `mtpr-synfix.service`;
- `mtpr-nft-synfix.service`;
- таблиц `MTProto` и `mtpr_synfix`;
- публичных портов `8080` и `9091`.

Если на сервере ранее выполнялись старые установщики из изменяемых веток `main` и сервер обрабатывает ценные данные, наиболее надёжное восстановление доверия — новый VPS из чистого образа с переносом только проверенных конфигураций.
