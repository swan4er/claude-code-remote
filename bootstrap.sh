#!/usr/bin/env bash
# Vibecoder School VPS bootstrap
# Supported server OS: Ubuntu Server 24.04 LTS and 26.04 LTS

set -Eeuo pipefail
umask 022

readonly INSTALLER_VERSION="2026.09.18.1"
readonly VIBE_USER="vibe"
readonly VIBE_HOME="/home/${VIBE_USER}"
readonly STATE_DIR="/var/lib/vibecoder-installer"
readonly LOG_FILE="/var/log/vibecoder-installer.log"
readonly SSH_DROPIN="/etc/ssh/sshd_config.d/00-vibecoder-hardening.conf"
readonly CLAUDE_KEY_FINGERPRINT="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
readonly MOZILLA_KEY_FINGERPRINT="35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"

ACTION="${1:-prepare}"
CURRENT_STEP="startup"

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

info() { printf '\n[INFO] %s\n' "$*"; }
ok() { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf '\n[FAIL] Step "%s" failed (exit code %s).\n' "$CURRENT_STEP" "$exit_code" >&2
  printf '[FAIL] Full log: %s\n' "$LOG_FILE" >&2
  exit "$exit_code"
}
trap on_error ERR

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run bootstrap.sh as root."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

validate_number() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  (( "$1" >= "$2" && "$1" <= "$3" ))
}

load_os() {
  CURRENT_STEP="checking Ubuntu version"
  [[ -r /etc/os-release ]] || die "/etc/os-release is missing. Use a standard Ubuntu Server image."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "Unsupported server OS: ${PRETTY_NAME:-unknown}. Use Ubuntu Server 24.04 or 26.04 LTS."
  case "${VERSION_ID:-}" in
    24.04|26.04) ;;
    *) die "Unsupported Ubuntu version: ${VERSION_ID:-unknown}. Supported: 24.04 and 26.04 LTS." ;;
  esac
  [[ "$(ps -p 1 -o comm=)" == "systemd" ]] || die "systemd is required. Containers and minimal images without systemd are not supported."
  case "$(uname -m)" in
    x86_64|aarch64|arm64) ;;
    *) die "Unsupported CPU architecture: $(uname -m). Supported: x86_64 and ARM64." ;;
  esac
  ok "Supported OS detected: ${PRETTY_NAME} ($(uname -m))"
}

preflight_resources() {
  CURRENT_STEP="checking server resources"
  local memory_mb free_mb
  memory_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  free_mb=$(df -Pm / | awk 'NR==2{print $4}')

  if (( memory_mb < 3500 )); then
    if [[ "${VIBECODER_ALLOW_LOW_MEMORY:-0}" == "1" ]]; then
      warn "Only ${memory_mb} MB RAM detected. Claude Code officially requires 4 GB or more."
    else
      die "Only ${memory_mb} MB RAM detected. Choose a VPS with at least 4 GB RAM, or explicitly set VIBECODER_ALLOW_LOW_MEMORY=1."
    fi
  fi
  (( free_mb >= 7000 )) || die "At least 7 GB of free disk space is required; only ${free_mb} MB is available."
  ok "Resources are sufficient: ${memory_mb} MB RAM, ${free_mb} MB free disk"
}

wait_for_cloud_init() {
  CURRENT_STEP="waiting for cloud-init"
  if command -v cloud-init >/dev/null 2>&1 && cloud-init status 2>/dev/null | grep -qE 'status: (running|not run)'; then
    info "The hosting provider is still initializing Ubuntu. Waiting up to 5 minutes..."
    timeout 300 cloud-init status --wait >/dev/null || die "cloud-init did not finish within 5 minutes. Wait a little and run the installer again."
  fi
}

wait_for_apt() {
  CURRENT_STEP="waiting for apt locks"
  local waited=0
  apt_is_locked() {
    if command -v fuser >/dev/null 2>&1; then
      fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock >/dev/null 2>&1
    else
      lslocks -n -o PATH 2>/dev/null | grep -qE '^(/var/lib/dpkg/lock-frontend|/var/lib/dpkg/lock|/var/cache/apt/archives/lock)$'
    fi
  }
  while apt_is_locked; do
    (( waited < 300 )) || die "apt is still busy after 5 minutes. A provider update may be stuck."
    if (( waited % 30 == 0 )); then
      info "Another package operation is running; waiting..."
    fi
    sleep 5
    waited=$((waited + 5))
  done
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a
}

decode_public_key() {
  [[ -n "${VIBE_PUBLIC_KEY_B64:-}" ]] || die "VIBE_PUBLIC_KEY_B64 was not provided by the local installer."
  PUBLIC_KEY=$(printf '%s' "$VIBE_PUBLIC_KEY_B64" | base64 --decode 2>/dev/null) || die "The SSH public key could not be decoded."
  case "$PUBLIC_KEY" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *) ;;
    *) die "The supplied SSH public key has an unsupported format." ;;
  esac
}

install_base_packages() {
  CURRENT_STEP="installing Ubuntu packages"
  wait_for_apt
  apt-get update

  local packages=(
    ca-certificates curl wget gnupg git tmux openssh-server sudo
    ufw fail2ban unattended-upgrades
    xfce4 xfce4-terminal dbus-x11 xdg-utils
    tigervnc-standalone-server novnc websockify
  )

  local missing=() package
  for package in "${packages[@]}"; do
    apt-cache show "$package" >/dev/null 2>&1 || missing+=("$package")
  done
  ((${#missing[@]} == 0)) || die "Required Ubuntu packages are unavailable: ${missing[*]}. Check the Ubuntu image and apt sources."

  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
  ok "Base packages installed"
}

create_vibe_user() {
  CURRENT_STEP="creating the vibe user"
  if id "$VIBE_USER" >/dev/null 2>&1; then
    [[ "$(getent passwd "$VIBE_USER" | cut -d: -f6)" == "$VIBE_HOME" ]] || die "User '$VIBE_USER' already exists with a non-standard home directory. Use a fresh VPS or resolve this account manually."
    usermod -s /bin/bash "$VIBE_USER"
  else
    useradd --create-home --home-dir "$VIBE_HOME" --shell /bin/bash "$VIBE_USER"
  fi
  usermod -aG sudo "$VIBE_USER"
  passwd -l "$VIBE_USER" >/dev/null 2>&1 || true

  install -d -m 0700 -o "$VIBE_USER" -g "$VIBE_USER" "$VIBE_HOME/.ssh"
  touch "$VIBE_HOME/.ssh/authorized_keys"
  chown "$VIBE_USER:$VIBE_USER" "$VIBE_HOME/.ssh/authorized_keys"
  chmod 0600 "$VIBE_HOME/.ssh/authorized_keys"
  grep -qxF -- "$PUBLIC_KEY" "$VIBE_HOME/.ssh/authorized_keys" || printf '%s\n' "$PUBLIC_KEY" >> "$VIBE_HOME/.ssh/authorized_keys"
  chown "$VIBE_USER:$VIBE_USER" "$VIBE_HOME/.ssh/authorized_keys"

  cat > /etc/sudoers.d/90-vibecoder-vibe <<'EOF'
vibe ALL=(ALL:ALL) NOPASSWD: ALL
EOF
  chmod 0440 /etc/sudoers.d/90-vibecoder-vibe
  visudo -cf /etc/sudoers.d/90-vibecoder-vibe >/dev/null
  ok "User '$VIBE_USER' is ready for SSH and passwordless sudo"
}

verify_gpg_fingerprint() {
  local key_file=$1 expected=$2 actual
  actual=$(gpg --batch --show-keys --with-colons "$key_file" 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}')
  [[ "$actual" == "$expected" ]] || die "Signing-key fingerprint mismatch for $key_file. Expected $expected, got ${actual:-nothing}."
}

install_firefox() {
  CURRENT_STEP="installing Firefox from Mozilla"
  install -d -m 0755 /etc/apt/keyrings
  curl --fail --silent --show-error --location --retry 3 \
    https://packages.mozilla.org/apt/repo-signing-key.gpg \
    --output /etc/apt/keyrings/packages.mozilla.org.asc
  verify_gpg_fingerprint /etc/apt/keyrings/packages.mozilla.org.asc "$MOZILLA_KEY_FINGERPRINT"

  cat > /etc/apt/sources.list.d/mozilla.sources <<'EOF'
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF

  cat > /etc/apt/preferences.d/mozilla <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000

Package: firefox
Pin: release o=Ubuntu
Pin-Priority: -1
EOF

  wait_for_apt
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y firefox
  command -v firefox >/dev/null 2>&1 || die "Firefox installation completed, but the firefox command is missing."
  if readlink -f "$(command -v firefox)" | grep -q '/snap/'; then
    die "Firefox resolved to a Snap package. The installer requires Mozilla's DEB build for reliable use inside VNC."
  fi
  ok "Firefox DEB installed: $(firefox --version 2>/dev/null | head -n1)"
}

install_claude_code() {
  CURRENT_STEP="installing Claude Code"
  install -d -m 0755 /etc/apt/keyrings
  curl --fail --silent --show-error --location --retry 3 \
    https://downloads.claude.ai/keys/claude-code.asc \
    --output /etc/apt/keyrings/claude-code.asc
  verify_gpg_fingerprint /etc/apt/keyrings/claude-code.asc "$CLAUDE_KEY_FINGERPRINT"

  cat > /etc/apt/sources.list.d/claude-code.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main
EOF

  wait_for_apt
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y claude-code
  sudo -u "$VIBE_USER" -H claude --version >/dev/null
  ok "Claude Code installed on the stable channel: $(sudo -u "$VIBE_USER" -H claude --version | head -n1)"
}

port_is_listening() {
  local port=$1
  ss -H -ltn | awk -v suffix=":${port}" '$4 ~ suffix "$" {found=1} END {exit !found}'
}

configure_desktop() {
  CURRENT_STEP="configuring XFCE and Claude login"
  install -d -m 0700 -o "$VIBE_USER" -g "$VIBE_USER" \
    "$VIBE_HOME/.vnc" "$VIBE_HOME/.config/autostart" "$VIBE_HOME/.config" \
    "$VIBE_HOME/.local/bin" "$VIBE_HOME/Desktop"

  cat > "$VIBE_HOME/.vnc/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_DESKTOP=xfce
export LANG=C.UTF-8
exec dbus-launch --exit-with-session startxfce4
EOF
  chmod 0700 "$VIBE_HOME/.vnc/xstartup"

  cat > "$VIBE_HOME/.config/mimeapps.list" <<'EOF'
[Default Applications]
text/html=firefox.desktop
x-scheme-handler/http=firefox.desktop
x-scheme-handler/https=firefox.desktop
EOF

  cat > "$VIBE_HOME/.local/bin/vibecoder-claude-login" <<'EOF'
#!/usr/bin/env bash
set -u
export PATH="/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin"
if [[ "${1:-}" != "--force" && -s "${HOME}/.claude/.credentials.json" ]]; then
  exit 0
fi
sleep 3
exec xfce4-terminal \
  --title="Claude Code login" \
  --hold \
  --command="bash -lc 'unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; claude; exec bash'"
EOF
  chmod 0755 "$VIBE_HOME/.local/bin/vibecoder-claude-login"

  cat > "$VIBE_HOME/.config/autostart/vibecoder-claude-login.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Claude Code login
Comment=Open Claude Code login on the VPS
Exec=${VIBE_HOME}/.local/bin/vibecoder-claude-login
Terminal=false
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
EOF

  cat > "$VIBE_HOME/Desktop/Claude Code Login.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Log in to Claude Code
Comment=Run the Claude Code browser login on this VPS
Exec=${VIBE_HOME}/.local/bin/vibecoder-claude-login --force
Icon=firefox
Terminal=false
EOF
  chmod 0755 "$VIBE_HOME/Desktop/Claude Code Login.desktop"
  chown -R "$VIBE_USER:$VIBE_USER" "$VIBE_HOME/.vnc" "$VIBE_HOME/.config" "$VIBE_HOME/.local" "$VIBE_HOME/Desktop"
  ok "XFCE login launcher configured"
}

configure_vnc_services() {
  CURRENT_STEP="configuring VNC and noVNC"
  local vnc_server novnc_proxy
  vnc_server=$(command -v tigervncserver || command -v vncserver || true)
  [[ -n "$vnc_server" ]] || die "TigerVNC server command was not found after package installation."

  if command -v novnc_proxy >/dev/null 2>&1; then
    novnc_proxy=$(command -v novnc_proxy)
  elif [[ -x /usr/share/novnc/utils/novnc_proxy ]]; then
    novnc_proxy=/usr/share/novnc/utils/novnc_proxy
  else
    die "noVNC proxy command was not found after package installation."
  fi

  systemctl stop vibecoder-novnc.service vibecoder-vnc.service >/dev/null 2>&1 || true
  sleep 1
  port_is_listening 5901 && die "TCP port 5901 is already used by software not managed by this installer."
  port_is_listening 6080 && die "TCP port 6080 is already used by software not managed by this installer."

  cat > /etc/systemd/system/vibecoder-vnc.service <<EOF
[Unit]
Description=Vibecoder School private TigerVNC desktop
After=network.target

[Service]
Type=forking
User=${VIBE_USER}
Group=${VIBE_USER}
WorkingDirectory=${VIBE_HOME}
Environment=HOME=${VIBE_HOME}
Environment=USER=${VIBE_USER}
PIDFile=${VIBE_HOME}/.vnc/%H:1.pid
ExecStartPre=-${vnc_server} -kill :1
ExecStart=${vnc_server} :1 -localhost yes -SecurityTypes None -geometry 1440x900 -depth 24
ExecStop=-${vnc_server} -kill :1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/vibecoder-novnc.service <<EOF
[Unit]
Description=Vibecoder School private noVNC gateway
After=network.target vibecoder-vnc.service
Requires=vibecoder-vnc.service

[Service]
Type=simple
User=${VIBE_USER}
Group=${VIBE_USER}
WorkingDirectory=${VIBE_HOME}
ExecStart=${novnc_proxy} --listen 127.0.0.1:6080 --vnc 127.0.0.1:5901
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now vibecoder-vnc.service
  systemctl enable --now vibecoder-novnc.service

  local _
  for _ in {1..20}; do
    if curl --fail --silent http://127.0.0.1:6080/vnc.html >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  systemctl is-active --quiet vibecoder-vnc.service || {
    systemctl status vibecoder-vnc.service --no-pager || true
    die "TigerVNC failed to start."
  }
  systemctl is-active --quiet vibecoder-novnc.service || {
    systemctl status vibecoder-novnc.service --no-pager || true
    die "noVNC failed to start."
  }
  curl --fail --silent http://127.0.0.1:6080/vnc.html >/dev/null || die "noVNC is active but its web page is not responding."
  ok "Private desktop is available only at VPS localhost:6080"
}

configure_updates() {
  CURRENT_STEP="enabling security updates"
  systemctl enable --now unattended-upgrades.service
  ok "Automatic security updates enabled"
}

find_unexpected_public_ports() {
  local ssh_port=$1
  ss -H -ltn | awk -v ssh_port="$ssh_port" '
    {
      address=$4
      if (address ~ /^127\./ || address ~ /^\[?::1\]?:/) next
      port=address
      sub(/^.*:/, "", port)
      if (port != ssh_port) print address
    }
  ' | sort -u
}

configure_firewall_and_fail2ban() {
  local ssh_port=$1 unexpected
  CURRENT_STEP="configuring firewall and fail2ban"

  if [[ ! -f "$STATE_DIR/hardened" ]]; then
    unexpected=$(find_unexpected_public_ports "$ssh_port")
    if [[ -n "$unexpected" && "${VIBECODER_ALLOW_PUBLIC_PORTS:-0}" != "1" ]]; then
      printf '%s\n' "$unexpected" >&2
      die "Unexpected public listening ports were found. This may be provider software or a non-clean VPS. The installer stopped before changing the firewall."
    fi
  fi

  ufw allow "${ssh_port}/tcp" comment 'Vibecoder SSH' >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw --force enable >/dev/null

  cat > /etc/fail2ban/jail.d/vibecoder-sshd.local <<EOF
[sshd]
enabled = true
port = ${ssh_port}
backend = systemd
EOF
  systemctl enable --now fail2ban.service
  ufw status | grep -q "${ssh_port}/tcp" || die "UFW does not show an allow rule for SSH port ${ssh_port}."
  ok "UFW and fail2ban configured for SSH port ${ssh_port}"
}

harden_ssh() {
  local ssh_port="" effective configured_port
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    ssh_port=$(awk '{print $4}' <<<"$SSH_CONNECTION")
  fi
  configured_port=$(sshd -T | awk '$1 == "port" {print $2; exit}')
  if ! validate_number "${ssh_port:-}" 1 65535; then
    ssh_port="$configured_port"
  fi
  if ! validate_number "${ssh_port:-}" 1 65535; then
    ssh_port=${VIBECODER_SSH_PORT:-22}
  fi
  validate_number "$ssh_port" 1 65535 || die "Invalid SSH port: $ssh_port"
  info "Server-side SSH port detected as ${ssh_port} (the public provider port may differ if NAT is used)."
  [[ -s "$VIBE_HOME/.ssh/authorized_keys" ]] || die "The vibe SSH key is missing; refusing to harden SSH."

  if [[ -f "$STATE_DIR/hardened" ]]; then
    info "SSH hardening was already completed; validating current state."
  fi

  configure_firewall_and_fail2ban "$ssh_port"
  CURRENT_STEP="hardening SSH"
  install -d -m 0755 /etc/ssh/sshd_config.d
  cat > "$SSH_DROPIN" <<'EOF'
# Managed by Vibecoder School VPS installer.
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
  chmod 0644 "$SSH_DROPIN"
  sshd -t
  systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service

  effective=$(sshd -T | awk '
    $1 == "permitrootlogin" || $1 == "passwordauthentication" ||
    $1 == "kbdinteractiveauthentication" || $1 == "pubkeyauthentication" {print $1 " " $2}
  ')
  grep -qx 'permitrootlogin no' <<<"$effective" || die "Effective SSH configuration still permits root login. A provider config may override the managed file."
  grep -qx 'passwordauthentication no' <<<"$effective" || die "Effective SSH configuration still permits password authentication."
  grep -qx 'kbdinteractiveauthentication no' <<<"$effective" || die "Effective SSH configuration still permits keyboard-interactive authentication."
  grep -qx 'pubkeyauthentication yes' <<<"$effective" || die "Effective SSH configuration does not permit public-key authentication."

  date -u +'%Y-%m-%dT%H:%M:%SZ' > "$STATE_DIR/hardened"
  ok "SSH accepts keys for vibe and rejects root/password login"
}

verify_installation() {
  CURRENT_STEP="verifying installation"
  id "$VIBE_USER" >/dev/null
  sudo -u "$VIBE_USER" -H claude --version >/dev/null
  command -v firefox >/dev/null
  systemctl is-active --quiet vibecoder-vnc.service
  systemctl is-active --quiet vibecoder-novnc.service
  curl --fail --silent http://127.0.0.1:6080/vnc.html >/dev/null
  ss -H -ltn | grep -qE '127\.0\.0\.1:5901|\[::1\]:5901'
  ss -H -ltn | grep -qE '127\.0\.0\.1:6080|\[::1\]:6080'
  [[ -s "$VIBE_HOME/.ssh/authorized_keys" ]]
  ok "All server-side checks passed"
}

prepare() {
  decode_public_key
  load_os
  preflight_resources
  wait_for_cloud_init
  install_base_packages
  create_vibe_user
  install_firefox
  install_claude_code
  configure_desktop
  configure_vnc_services
  configure_updates
  verify_installation
  date -u +'%Y-%m-%dT%H:%M:%SZ' > "$STATE_DIR/prepared"
  printf '\nSERVER_PREPARED installer_version=%s\n' "$INSTALLER_VERSION"
}

main() {
  require_root
  require_command base64
  require_command flock
  require_command ss

  exec 9>/var/lock/vibecoder-installer.lock
  flock -n 9 || die "Another Vibecoder installer process is already running."

  case "$ACTION" in
    prepare) prepare ;;
    harden)
      load_os
      [[ -f "$STATE_DIR/prepared" ]] || die "Run the prepare phase before hardening."
      harden_ssh
      verify_installation
      printf '\nSERVER_HARDENED installer_version=%s\n' "$INSTALLER_VERSION"
      ;;
    verify)
      load_os
      verify_installation
      ;;
    *) die "Unknown action '$ACTION'. Use: prepare, harden, or verify." ;;
  esac
}

main "$@"
