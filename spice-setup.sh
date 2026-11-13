#!/usr/bin/env bash
# spice-setup.sh - install and enable the SPICE guest agent inside a Linux VM
# so copy/paste and auto-resize work in Remote Viewer (virt-viewer).
#
# Run INSIDE the VM (not on the Proxmox host):
#   sudo bash spice-setup.sh              # set up for the user who ran sudo
#   sudo bash spice-setup.sh --all-users  # every desktop user, plus new users
#
# Proxmox host side (once per VM): qm set <vmid> --vga qxl, then fully stop/start the VM.

set -euo pipefail

ALL_USERS=0
AUTOSTART_NAME="spice-vdagent.desktop"
SPICE_PORT="/dev/virtio-ports/com.redhat.spice.0"

info() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

for arg in "$@"; do
  case "$arg" in
    --all-users) ALL_USERS=1 ;;
    -h|--help)   usage ;;
    *)           die "Unknown option: $arg (try --help)" ;;
  esac
done

# Re-run as root if needed
if [[ $EUID -ne 0 ]]; then
  info "Root needed, re-running with sudo..."
  exec sudo bash "$0" "$@"
fi

# --- 1. Install the agent ---------------------------------------------------
install_agent() {
  if command -v spice-vdagent >/dev/null 2>&1; then
    ok "spice-vdagent is already installed"
    return 0
  fi
  info "Installing spice-vdagent..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq spice-vdagent
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q spice-vdagent
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q spice-vdagent
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install spice-vdagent
  elif command -v pacman >/dev/null 2>&1; then
    pacman -S --noconfirm --needed spice-vdagent
  else
    die "No supported package manager found (apt, dnf, yum, zypper, pacman)."
  fi
  ok "spice-vdagent installed"
}

# --- 2. Start the system daemon ---------------------------------------------
start_daemon() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "No systemd found; start spice-vdagentd with your init system."
    return 0
  fi
  # On Debian/Kali/Ubuntu the service is "static" and socket/udev-activated,
  # so we enable the socket (harmless where unsupported) and start the service.
  systemctl enable --now spice-vdagentd.socket >/dev/null 2>&1 || true
  if [[ -e $SPICE_PORT ]]; then
    systemctl start spice-vdagentd.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet spice-vdagentd.service; then
      ok "spice-vdagentd daemon is running"
    else
      warn "spice-vdagentd didn't start; check: systemctl status spice-vdagentd"
    fi
  fi
}

# --- 3. Desktop autostart ---------------------------------------------------
has_desktop() {
  compgen -G "/usr/share/xsessions/*.desktop" >/dev/null ||
    compgen -G "/usr/share/wayland-sessions/*.desktop" >/dev/null
}

target_users() {
  if (( ALL_USERS )); then
    getent passwd | awk -F: '$3>=1000 && $3<60000 && $6 ~ /^\/home\// {print $1}'
  elif [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    echo "$SUDO_USER"
  fi
}

AUTOSTART_CONTENT='[Desktop Entry]
Type=Application
Name=Spice vdagent
Comment=SPICE agent for clipboard sharing and display resizing
Exec=spice-vdagent
Hidden=false
X-GNOME-Autostart-enabled=true'

# $1 = autostart directory, $2 = owner (empty = root, used for /etc/skel)
write_autostart() {
  local dir="$1" owner="$2" file="$1/$AUTOSTART_NAME"
  if [[ -f $file ]] &&
     ! grep -qiE '^[[:space:]]*(Hidden[[:space:]]*=[[:space:]]*true|X-GNOME-Autostart-enabled[[:space:]]*=[[:space:]]*false)' "$file"; then
    ok "Autostart already enabled: $file"
    return 0
  fi
  if [[ -n $owner ]]; then
    runuser -u "$owner" -- mkdir -p "$dir"
    printf '%s\n' "$AUTOSTART_CONTENT" | runuser -u "$owner" -- tee "$file" >/dev/null
  else
    mkdir -p "$dir"
    printf '%s\n' "$AUTOSTART_CONTENT" > "$file"
  fi
  chmod 644 "$file"
  ok "Created autostart file: $file"
}

# Start the desktop agent right away if the user is logged into a desktop
start_user_agent() {
  local user="$1" uid pid envs display="" xauth=""
  uid=$(id -u "$user")
  if pgrep -u "$uid" -x spice-vdagent >/dev/null 2>&1; then
    ok "Desktop agent already running for $user"
    return 0
  fi
  [[ -e $SPICE_PORT ]] || return 0
  for pid in $(pgrep -u "$uid" || true); do
    envs=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null) || continue
    display=$(grep -m1 '^DISPLAY=' <<<"$envs" | cut -d= -f2- || true)
    if [[ -n $display ]]; then
      xauth=$(grep -m1 '^XAUTHORITY=' <<<"$envs" | cut -d= -f2- || true)
      break
    fi
  done
  if [[ -z $display ]]; then
    warn "$user isn't logged into a desktop right now; the agent starts at next login."
    return 0
  fi
  local envargs=("DISPLAY=$display" "XDG_RUNTIME_DIR=/run/user/$uid")
  if [[ -n $xauth ]]; then envargs+=("XAUTHORITY=$xauth"); fi
  runuser -u "$user" -- env "${envargs[@]}" spice-vdagent >/dev/null 2>&1 || true
  sleep 1
  if pgrep -u "$uid" -x spice-vdagent >/dev/null 2>&1; then
    ok "Started desktop agent for $user (copy/paste should work now)"
  else
    warn "Couldn't start the agent for $user; log out and back in."
  fi
}

# --- Main -------------------------------------------------------------------
main() {
  info "SPICE guest agent setup"
  install_agent

  if [[ -e $SPICE_PORT ]]; then
    ok "SPICE channel found ($SPICE_PORT)"
  else
    warn "SPICE channel not found. On the Proxmox host run: qm set <vmid> --vga qxl"
    warn "then fully Shutdown and Start the VM (a reboot from inside isn't enough)."
  fi

  start_daemon

  if ! has_desktop; then
    warn "No desktop environment found. Clipboard sharing needs a desktop; use SSH instead."
  else
    local users=() u home
    mapfile -t users < <(target_users)
    if (( ${#users[@]} == 0 )); then
      warn "No target user found. Run with sudo from your account, or use --all-users."
    fi
    for u in "${users[@]}"; do
      home=$(getent passwd "$u" | cut -d: -f6)
      [[ -d $home ]] || { warn "Home for $u not found, skipping"; continue; }
      write_autostart "$home/.config/autostart" "$u"
      start_user_agent "$u"
    done
    if (( ALL_USERS )); then
      write_autostart "/etc/skel/.config/autostart" ""
    fi
  fi

  echo
  info "Running SPICE processes (want both spice-vdagentd and spice-vdagent):"
  pgrep -a spice-vdagent || echo "    (none yet)"
  echo
  ok "Done. Paste inside the VM terminal with Ctrl+Shift+V."
}

main
