#!/usr/bin/env bash
set -Eeuo pipefail
DIR=/opt/bobr-checker
cd "$DIR"

set_env_val() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$DIR/.env"; then
    sed -i "s|^${key}=.*|${key}='${val}'|" "$DIR/.env"
  else
    printf "%s='%s'\n" "$key" "$val" >> "$DIR/.env"
  fi
}

get_domain() {
  awk -F= '$1=="DOMAIN"{print $2}' "$DIR/.env" | tr -d "'\" "
}

case "${1:-help}" in
  status) docker compose ps ;;
  logs) docker compose logs -f --tail=200 ;;
  restart) docker compose restart ;;
  update)
    [[ $EUID -eq 0 ]] || { echo "Запусти: sudo bcheck update"; exit 1; }
    [[ -f "$DIR/.env" ]] || { echo "Не найден $DIR/.env"; exit 1; }
    SOURCE_FILE="/etc/bobr-checker/source-dir"
    [[ -s "$SOURCE_FILE" ]] || { echo "Не найден путь к Git-репозиторию: $SOURCE_FILE"; exit 1; }
    SRC_DIR="$(tr -d '\r\n' < "$SOURCE_FILE" | sed 's/\\n$//; s/[[:space:]]*$//')"
    [[ -d "$SRC_DIR/.git" ]] || { echo "Git-репозиторий не найден: [$SRC_DIR]"; exit 1; }

    echo "1/5 Проверяю и обновляю исходники..."
    git -C "$SRC_DIR" pull --ff-only
    echo "2/5 Сохраняю конфигурацию и обновляю файлы..."
    cp -a "$DIR/.env" "$DIR/.env.backup.$(date +%Y%m%d%H%M%S)"
    mkdir -p "$DIR/custom"
    cp -a "$SRC_DIR/custom/." "$DIR/custom/"
    install -m 644 "$SRC_DIR/docker-compose.yml" "$DIR/docker-compose.yml"
    [[ ! -f "$SRC_DIR/Caddyfile" ]] || install -m 644 "$SRC_DIR/Caddyfile" "$DIR/Caddyfile"
    [[ ! -f "$SRC_DIR/README.md" ]] || install -m 644 "$SRC_DIR/README.md" "$DIR/README.md"
    chown -R 1000:1000 "$DIR/custom"

    tmp="$(mktemp)"
    if grep -q '^SUBSCRIPTION_JSON_FORMAT=' "$DIR/.env"; then
      sed 's/^SUBSCRIPTION_JSON_FORMAT=.*/SUBSCRIPTION_JSON_FORMAT=true/' "$DIR/.env" > "$tmp"
    else
      cat "$DIR/.env" > "$tmp"
      printf '\nSUBSCRIPTION_JSON_FORMAT=true\n' >> "$tmp"
    fi
    install -m 600 "$tmp" "$DIR/.env"
    rm -f "$tmp"

    echo "3/5 Проверяю конфигурацию и обновляю образы..."
    cd "$DIR"
    docker compose config -q
    docker compose pull
    docker compose up -d --remove-orphans
    docker compose restart caddy >/dev/null 2>&1 || true

    echo "4/5 Обновляю команду управления..."
    install -m 755 "$SRC_DIR/cli.sh" /usr/local/bin/bobr-checker
    ln -sf /usr/local/bin/bobr-checker /usr/local/bin/bcheck

    echo "5/5 Жду готовности Checker..."
    ready=0
    for _ in $(seq 1 45); do
      if docker compose exec -T checker-my curl -fsS http://127.0.0.1:2112/health >/dev/null 2>&1; then ready=1; break; fi
      sleep 2
    done
    if [[ "$ready" != 1 ]]; then
      docker compose ps
      docker compose logs --tail=100 checker-my
      echo "Checker не прошёл healthcheck." >&2
      exit 1
    fi
    echo "Готово: исходники, интерфейс и контейнеры обновлены; Checker healthy."
    ;;
  config)
    echo "=== Настройка подписок по группам ==="
    current_my="$(grep '^SUB_URL_MY=' "$DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)"
    [[ -n "$current_my" ]] || current_my="$(grep '^SUBSCRIPTION_URL=' "$DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)"
    current_f1="$(grep '^SUB_URL_FRIEND1=' "$DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)"
    current_f2="$(grep '^SUB_URL_FRIEND2=' "$DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)"

    read -r -p "1. Ссылка для вашей группы ${current_my:+[оставить текущую]}: " in_my
    in_my="${in_my:-$current_my}"
    [[ -n "$in_my" ]] && set_env_val "SUB_URL_MY" "$in_my" && set_env_val "SUBSCRIPTION_URL" "$in_my"

    read -r -p "2. Ссылка для группы Друга 1 ${current_f1:+[оставить текущую]}: " in_f1
    in_f1="${in_f1:-$current_f1}"
    [[ -n "$in_f1" ]] && set_env_val "SUB_URL_FRIEND1" "$in_f1"

    read -r -p "3. Ссылка для группы Друга 2 ${current_f2:+[оставить текущую]}: " in_f2
    in_f2="${in_f2:-$current_f2}"
    [[ -n "$in_f2" ]] && set_env_val "SUB_URL_FRIEND2" "$in_f2"

    echo "Перезапускаю сервисы..."
    docker compose up -d --remove-orphans
    docker compose restart caddy >/dev/null 2>&1 || true
    d="$(get_domain)"
    echo "----------------------------------------"
    echo "Готово! Ссылки API для вашего бота:"
    echo "• Ваша группа:    https://${d}/api/my/api/v1/public/proxies"
    echo "• Группа Друга 1: https://${d}/api/friend1/api/v1/public/proxies"
    echo "• Группа Друга 2: https://${d}/api/friend2/api/v1/public/proxies"
    echo "• Веб-панель:     https://${d}/"
    echo "----------------------------------------"
    ;;
  uninstall)
    echo "Контейнер и файлы приложения будут удалены."
    read -r -p "Для подтверждения введите DELETE: " answer
    [[ "$answer" == DELETE ]] || exit 0
    docker compose down
    cd /
    rm -rf "$DIR"
    rm -f /usr/local/bin/bobr-checker /usr/local/bin/bcheck
    echo "Bobr Cloud Checker удалён."
    ;;
  help|--help|-h)
    echo "Bobr Checker команды: status | logs | restart | update | config | uninstall"
    echo "Быстрая команда: bcheck update | bcheck config"
    ;;
  *) echo "Неизвестная команда. Используйте: bobr-checker help"; exit 2 ;;
esac
