#!/usr/bin/env bash
# ============================================================
#  pc_report_remote.sh — запуск сервиса на УДАЛЁННОМ Linux-ПК по SSH
#
#  Запуск:      ./pc_report_remote.sh user@host [-o файл.html]
#               PC_PASS='секрет' ./pc_report_remote.sh mike@192.168.1.154
#               (или запустить без PC_PASS — тогда будет запрошен
#                ввод пароля через ssh-add / интерактив)
#
#  Безопасность:
#   - Пароль передаётся ТОЛЬКО через переменную окружения PC_PASS
#     процессу sshpass и НЕ записывается ни в один файл.
#   - Сервисные скрипты копируются во временный каталог на удалённой
#     машине, выполняются, HTML скачивается, временные файлы удаляются.
#   - Сначала пробуются SSH-ключи из стандартных мест (~/.ssh/id_*);
#     пароль нужен только если ключевая аутентификация не прошла.
# ============================================================
set -u

[ $# -ge 1 ] || { echo "Использование: $0 user@host [-o output.html]" >&2; exit 1; }
TARGET="$1"; shift
OUTPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) OUTPUT="$2"; shift 2 ;;
    *) echo "Неизвестный параметр: $1" >&2; exit 1 ;;
  esac
done

say() { printf '\033[1;36m[pc_report_remote]\033[0m %s\n' "$1" >&2; }
die() { printf '\033[1;31m[pc_report_remote] ОШИБКА:\033[0m %s\n' "$1" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

# --- попытка №1: ключевая аутентификация (стандартные места ~/.ssh/id_*) ---
try_key() {
  if ssh $SSH_OPTS "$TARGET" true 2>/dev/null; then return 0; fi
  # явный перебор стандартных ключей
  for k in "$HOME"/.ssh/id_rsa "$HOME"/.ssh/id_ed25519 "$HOME"/.ssh/id_ecdsa; do
    [ -f "$k" ] && ssh $SSH_OPTS -i "$k" "$TARGET" true 2>/dev/null && { KEYARG="-i $k"; return 0; }
  done
  return 1
}

KEYARG=""
USE_SSHPASS=0
if try_key; then
  say "Аутентификация по SSH-ключу — успешно."
else
  say "SSH-ключи в стандартных местах не подошли."
  if [ -n "${PC_PASS:-}" ] && command -v sshpass >/dev/null 2>&1; then
    USE_SSHPASS=1
    SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
    say "Использую пароль из переменной окружения (в памяти сессии, без сохранения)."
  else
    die "Нужен пароль: перезапустите как PC_PASS='пароль' $0 $TARGET (данные не сохраняются нигде) или настройте SSH-ключ."
  fi
fi

run_ssh() {
  if [ "$USE_SSHPASS" = 1 ]; then
    sshpass -e ssh $SSH_OPTS $KEYARG "$TARGET" "$@"
  else
    ssh $SSH_OPTS $KEYARG "$TARGET" "$@"
  fi
}

REMOTE_TMP="/tmp/.pcreport_$$_$(date +%s)"
LOCAL_OUT="$OUTPUT"
[ -n "$LOCAL_OUT" ] || LOCAL_OUT="PC_Report_$(echo "$TARGET" | tr '@.' '__')_$(date '+%Y%m%d_%H%M%S').html"

cleanup() { run_ssh "rm -rf '$REMOTE_TMP'" >/dev/null 2>&1 || true; }
trap cleanup EXIT

say "Подготовка удалённого окружения..."
run_ssh "mkdir -p '$REMOTE_TMP'" || die "Не удалось подключиться к $TARGET"

# копируем сервисные файлы (collect.sh + pc_report.sh)
for f in collect.sh pc_report.sh; do
  if [ "$USE_SSHPASS" = 1 ]; then
    sshpass -e scp -q -o StrictHostKeyChecking=accept-new "$HERE/$f" "$TARGET:$REMOTE_TMP/" || die "scp failed ($f)"
  else
    scp -q -o BatchMode=yes $KEYARG "$HERE/$f" "$TARGET:$REMOTE_TMP/" || die "scp failed ($f)"
  fi
done

say "Сбор данных на удалённом ПК..."
run_ssh "bash '$REMOTE_TMP/pc_report.sh' -o '$REMOTE_TMP/report.html'" >/dev/null || die "Сервис на удалённой машине завершился с ошибкой"

say "Скачивание HTML-отчёта..."
if [ "$USE_SSHPASS" = 1 ]; then
  sshpass -e scp -q -o StrictHostKeyChecking=accept-new "$TARGET:$REMOTE_TMP/report.html" "$LOCAL_OUT" || die "scp download failed"
else
  scp -q -o BatchMode=yes $KEYARG "$TARGET:$REMOTE_TMP/report.html" "$LOCAL_OUT" || die "scp download failed"
fi

cleanup; trap - EXIT
say "Готово: $LOCAL_OUT"
