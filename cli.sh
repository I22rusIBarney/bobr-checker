#!/usr/bin/env bash
set -Eeuo pipefail
DIR=/opt/bobr-checker
cd "$DIR"
case "${1:-help}" in
  status) docker compose ps ;;
  logs) docker compose logs -f --tail=200 ;;
  restart) docker compose restart ;;
  update)
    [[ $EUID -eq 0 ]] || { echo "Запусти: sudo bcheck update"; exit 1; }
    [[ -f "$DIR/.env" ]] || { echo "Не найден $DIR/.env"; exit 1; }
    SOURCE_FILE="/etc/bobr-checker/source-dir"
    [[ -s "$SOURCE_FILE" ]] || { echo "Не найден путь к Git-репозиторию: $SOURCE_FILE"; exit 1; }
    SRC_DIR="$(cat "$SOURCE_FILE")"
    [[ -d "$SRC_DIR/.git" ]] || { echo "Git-репозиторий не найден: $SRC_DIR"; exit 1; }

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

    echo "4/5 Обновляю команду управления..."
    install -m 755 "$SRC_DIR/cli.sh" /usr/local/bin/bobr-checker
    ln -sf /usr/local/bin/bobr-checker /usr/local/bin/bcheck

    echo "5/5 Жду готовности Checker..."
    ready=0
    for _ in $(seq 1 45); do
      if docker compose exec -T checker curl -fsS http://127.0.0.1:2112/health >/dev/null 2>&1; then ready=1; break; fi
      sleep 2
    done
    if [[ "$ready" != 1 ]]; then
      docker compose ps
      docker compose logs --tail=100 checker
      echo "Checker не прошёл healthcheck." >&2
      exit 1
    fi
    echo "Готово: исходники, интерфейс и контейнер обновлены; Checker healthy."
    ;;
  config) "${EDITOR:-nano}" "$DIR/.env" ;;
  uninstall)
    echo "Контейнер и файлы приложения будут удалены."
    read -r -p "Для подтверждения введите DELETE: " answer
    [[ "$answer" == DELETE ]] || exit 0
    docker compose down
    cd /
    rm -rf "$DIR"
    rm -f /usr/local/bin/bobr-checker
    echo "Bobr Cloud Checker удалён."
    ;;
  help|--help|-h)
    echo "Bobr Checker: status | logs | restart | update | config | uninstall\nКороткая команда: bcheck update"
    ;;
  *) echo "Неизвестная команда. Используйте: bobr-checker help"; exit 2 ;;
esac
