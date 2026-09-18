#!/usr/bin/env bash
# Vibecoder School local installer for macOS and Linux.

set -Eeuo pipefail
umask 077

readonly INSTALLER_VERSION="2026.09.18.1"
readonly DEFAULT_BASE_URL="https://raw.githubusercontent.com/swan4er/claude-code-remote/main"
readonly BASE_URL="${VIBECODER_BASE_URL:-$DEFAULT_BASE_URL}"
readonly SSH_ALIAS="vibecoder"

SERVER_HOST="${VIBECODER_SERVER_HOST:-}"
SSH_PORT="${VIBECODER_SSH_PORT:-22}"
SSH_DIR="${HOME}/.ssh"
KEY_PATH="${SSH_DIR}/vibecoder_vps_ed25519"
SSH_CONFIG="${SSH_DIR}/config"
TEMP_BOOTSTRAP=""

if [[ -t 1 ]]; then
  GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; RESET=$'\033[0m'
else
  GREEN=""; YELLOW=""; RED=""; RESET=""
fi

info() { printf '\n%s%s%s\n' "$YELLOW" "$*" "$RESET"; }
ok() { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%sВнимание:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() { printf '%sОшибка:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

cleanup() {
  [[ -z "$TEMP_BOOTSTRAP" || ! -f "$TEMP_BOOTSTRAP" ]] || rm -f "$TEMP_BOOTSTRAP"
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда '$1'. Установите OpenSSH Client и curl, затем повторите запуск."
}

validate_input() {
  [[ "$SERVER_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "Введите IPv4-адрес или домен сервера без http://, пробелов и дополнительных символов."
  if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    die "SSH-порт должен быть числом от 1 до 65535."
  fi
}

collect_input() {
  printf '\nVibecoder School — автоматическая настройка VPS\n'
  printf 'Поддерживаются Ubuntu Server 24.04 и 26.04 LTS.\n\n'

  if [[ -z "$SERVER_HOST" ]]; then
    [[ -r /dev/tty ]] || die "Не найден интерактивный терминал. Запустите команду из обычного Terminal."
    read -r -p "IP-адрес VPS: " SERVER_HOST < /dev/tty
  fi
  if [[ "${VIBECODER_SSH_PORT+x}" != "x" ]]; then
    local entered_port
    [[ -r /dev/tty ]] || die "Не найден интерактивный терминал. Запустите команду из обычного Terminal."
    read -r -p "SSH-порт [22]: " entered_port < /dev/tty
    SSH_PORT="${entered_port:-22}"
  fi
  validate_input
}

create_key() {
  mkdir -p "$SSH_DIR"
  chmod 0700 "$SSH_DIR"
  if [[ -f "$KEY_PATH" && ! -f "${KEY_PATH}.pub" ]]; then
    die "Найден приватный ключ без публичной части: $KEY_PATH. Не перезаписываю его автоматически."
  fi
  if [[ ! -f "$KEY_PATH" ]]; then
    info "Создаю отдельный SSH-ключ для Vibecoder School..."
    ssh-keygen -q -t ed25519 -a 64 -N "" -C "vibecoder-school" -f "$KEY_PATH"
    ok "SSH-ключ создан: $KEY_PATH"
  else
    ok "Использую существующий ключ: $KEY_PATH"
  fi
  chmod 0600 "$KEY_PATH"
  chmod 0644 "${KEY_PATH}.pub"
}

public_key_base64() {
  base64 < "${KEY_PATH}.pub" | tr -d '\r\n'
}

install_root_key() {
  local public_key_b64=$1 remote_command
  remote_command="umask 077; mkdir -p /root/.ssh; touch /root/.ssh/authorized_keys; chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys; KEY=\$(printf '%s' '${public_key_b64}' | base64 -d); grep -qxF -- \"\$KEY\" /root/.ssh/authorized_keys || printf '%s\\n' \"\$KEY\" >> /root/.ssh/authorized_keys"

  info "Подключаюсь к серверу как root."
  printf 'Сейчас сервер может один раз попросить пароль root.\n'
  printf 'Во время ввода пароля символы и звёздочки не отображаются — это нормально.\n\n'

  ssh \
    -p "$SSH_PORT" \
    -i "$KEY_PATH" \
    -o IdentitiesOnly=no \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=30 \
    -o StrictHostKeyChecking=accept-new \
    "root@${SERVER_HOST}" "$remote_command"
  ok "Выделенный ключ добавлен на сервер"
}

can_login_as_vibe() {
  ssh \
    -p "$SSH_PORT" \
    -i "$KEY_PATH" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new \
    "vibe@${SERVER_HOST}" true >/dev/null 2>&1
}

download_bootstrap() {
  TEMP_BOOTSTRAP=$(mktemp "${TMPDIR:-/tmp}/vibecoder-bootstrap.XXXXXX")
  info "Загружаю серверный установщик..."
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    "${BASE_URL}/bootstrap.sh?v=${INSTALLER_VERSION}" --output "$TEMP_BOOTSTRAP"
  [[ -s "$TEMP_BOOTSTRAP" ]] || die "Серверный установщик загрузился пустым файлом."
  head -n 1 "$TEMP_BOOTSTRAP" | grep -q '^#!/usr/bin/env bash' || die "По адресу bootstrap.sh получен неожиданный файл."
  grep -qF "readonly INSTALLER_VERSION=\"${INSTALLER_VERSION}\"" "$TEMP_BOOTSTRAP" || die "Версии локального и серверного установщиков не совпадают. Очистите кэш сайта/CDN и повторите запуск."
  chmod 0700 "$TEMP_BOOTSTRAP"
  ok "Серверный установщик загружен"
}

upload_bootstrap() {
  info "Передаю установщик на VPS..."
  if [[ "$CONNECTION_USER" == "root" ]]; then
    ssh -p "$SSH_PORT" -i "$KEY_PATH" -o IdentitiesOnly=yes "root@${SERVER_HOST}" \
      "install -d -m 700 /root/.cache/vibecoder"
    scp -q -P "$SSH_PORT" -i "$KEY_PATH" -o IdentitiesOnly=yes \
      "$TEMP_BOOTSTRAP" "root@${SERVER_HOST}:/root/.cache/vibecoder/bootstrap.sh"
    ssh -p "$SSH_PORT" -i "$KEY_PATH" -o IdentitiesOnly=yes "root@${SERVER_HOST}" \
      "chmod 700 /root/.cache/vibecoder/bootstrap.sh"
  else
    scp -q -P "$SSH_PORT" -i "$KEY_PATH" -o IdentitiesOnly=yes \
      "$TEMP_BOOTSTRAP" "vibe@${SERVER_HOST}:/tmp/vibecoder-bootstrap.sh"
    ssh -p "$SSH_PORT" -i "$KEY_PATH" -o IdentitiesOnly=yes "vibe@${SERVER_HOST}" \
      "sudo -n install -d -m 700 /root/.cache/vibecoder && sudo -n install -m 700 /tmp/vibecoder-bootstrap.sh /root/.cache/vibecoder/bootstrap.sh && rm -f /tmp/vibecoder-bootstrap.sh"
  fi
  ok "Установщик передан"
}

run_bootstrap_phase() {
  local phase=$1 public_key_b64=$2
  local remote_command="env VIBE_PUBLIC_KEY_B64='${public_key_b64}' VIBECODER_SSH_PORT='${SSH_PORT}' /root/.cache/vibecoder/bootstrap.sh '${phase}'"
  if [[ "$CONNECTION_USER" == "vibe" ]]; then
    remote_command="sudo -n ${remote_command}"
  fi
  ssh \
      -p "$SSH_PORT" \
      -i "$KEY_PATH" \
      -o IdentitiesOnly=yes \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=20 \
      "${CONNECTION_USER}@${SERVER_HOST}" \
      "$remote_command"
}

test_vibe_login() {
  info "Проверяю реальный вход с этого компьютера под пользователем vibe..."
  local result
  result=$(ssh \
    -p "$SSH_PORT" \
    -i "$KEY_PATH" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    "vibe@${SERVER_HOST}" "printf VIBE_LOGIN_OK") || die "Вход под vibe не прошёл. Root-доступ и вход по паролю пока НЕ отключены; исправьте причину и перезапустите установщик."
  [[ "$result" == "VIBE_LOGIN_OK" ]] || die "Сервер ответил неожиданным результатом при проверке пользователя vibe."
  ok "Вход под vibe по ключу работает"
}

write_ssh_config() {
  local begin_marker="# >>> Vibecoder School managed host >>>"
  local end_marker="# <<< Vibecoder School managed host <<<"
  local temp_config
  temp_config=$(mktemp "${TMPDIR:-/tmp}/vibecoder-ssh-config.XXXXXX")

  touch "$SSH_CONFIG"
  chmod 0600 "$SSH_CONFIG"
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "$SSH_CONFIG" > "$temp_config"

  {
    printf '\n%s\n' "$begin_marker"
    printf 'Host %s\n' "$SSH_ALIAS"
    printf '    HostName %s\n' "$SERVER_HOST"
    printf '    User vibe\n'
    printf '    Port %s\n' "$SSH_PORT"
    printf '    IdentityFile "%s"\n' "$KEY_PATH"
    printf '    IdentitiesOnly yes\n'
    printf '    ServerAliveInterval 30\n'
    printf '    ServerAliveCountMax 6\n'
    printf '%s\n' "$end_marker"
  } >> "$temp_config"

  mv "$temp_config" "$SSH_CONFIG"
  chmod 0600 "$SSH_CONFIG"
  ssh -G "$SSH_ALIAS" >/dev/null 2>&1 || die "Созданный SSH config не прошёл проверку."
  ok "В SSH добавлено подключение '$SSH_ALIAS'"
}

port_available() {
  local port=$1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$port" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
PY
  elif command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then return 1; else return 0; fi
  elif command -v ss >/dev/null 2>&1; then
    if ss -H -ltn | awk -v suffix=":${port}" '$4 ~ suffix "$" {found=1} END {exit !found}'; then return 1; else return 0; fi
  elif command -v nc >/dev/null 2>&1; then
    if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then return 1; else return 0; fi
  else
    [[ "$port" == "6080" ]]
  fi
}

choose_local_port() {
  local port
  for port in $(seq 6080 6099); do
    if port_available "$port"; then
      printf '%s' "$port"
      return 0
    fi
  done
  return 1
}

open_browser() {
  local url=$1
  if [[ "$(uname -s)" == "Darwin" ]] && command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 || warn "Не удалось открыть браузер автоматически. Откройте вручную: $url"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 &
  elif command -v gio >/dev/null 2>&1; then
    gio open "$url" >/dev/null 2>&1 &
  elif command -v wslview >/dev/null 2>&1; then
    wslview "$url" >/dev/null 2>&1
  else
    warn "Не удалось открыть браузер автоматически. Откройте вручную: $url"
  fi
}

start_novnc_tunnel() {
  local local_port url
  local_port=$(choose_local_port) || die "Локальные порты 6080–6099 заняты. Закройте старые SSH-туннели и повторите запуск."
  url="http://127.0.0.1:${local_port}/vnc.html?autoconnect=1&resize=remote"

  info "Открываю защищённый туннель к рабочему столу VPS..."
  ssh -fN \
    -o ExitOnForwardFailure=yes \
    -L "${local_port}:127.0.0.1:6080" \
    "$SSH_ALIAS"

  local _
  for _ in {1..20}; do
    if curl --fail --silent "http://127.0.0.1:${local_port}/vnc.html" >/dev/null 2>&1; then
      ok "Удалённый рабочий стол доступен через локальный порт ${local_port}"
      open_browser "$url"
      printf '\nОткрылся рабочий стол VPS. Внутри него работает Firefox с IP вашего сервера.\n'
      printf 'Не переносите ссылку авторизации в другую вкладку локального браузера.\n'
      printf 'Если браузер не открылся автоматически: %s\n' "$url"
      return 0
    fi
    sleep 1
  done
  die "SSH-туннель запущен, но страница noVNC не отвечает. Выполните: ssh vibecoder 'sudo systemctl status vibecoder-novnc --no-pager'"
}

main() {
  require_command ssh
  require_command scp
  require_command ssh-keygen
  require_command curl
  require_command base64
  collect_input
  create_key

  local public_key_b64
  public_key_b64=$(public_key_base64)
  if can_login_as_vibe; then
    CONNECTION_USER="vibe"
    ok "Сервер уже принимает ключ пользователя vibe; продолжаю безопасный повторный запуск"
  else
    CONNECTION_USER="root"
    install_root_key "$public_key_b64"
  fi
  download_bootstrap
  upload_bootstrap

  info "Готовлю Ubuntu, пользователя vibe, Claude Code и удалённый рабочий стол. Это может занять 10–20 минут..."
  run_bootstrap_phase prepare "$public_key_b64"

  test_vibe_login
  info "Безопасный вход под vibe подтверждён. Теперь отключаю root-login и вход по паролю..."
  run_bootstrap_phase harden "$public_key_b64"
  test_vibe_login

  write_ssh_config
  ok "Сервер полностью настроен (версия установщика ${INSTALLER_VERSION})"
  printf '\nВ VS Code выберите: Remote-SSH → Connect to Host → %s\n' "$SSH_ALIAS"
  start_novnc_tunnel
}

main "$@"
