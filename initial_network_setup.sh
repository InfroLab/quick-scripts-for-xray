#!/bin/bash
# ==============================================================================
#  initial_network_setup
#  Safe SSH + UFW + Fail2Ban + BBR setup with Full Restore
#  - Defaults to RESTORE mode (safer)
#  - Works with Ubuntu 22.04+
#  - Supports self-install into /usr/local/bin
#  - Automatically relaunches after install
# ==============================================================================

set -euo pipefail

# ------------------------------- UI Helpers -----------------------------------
banner() {
  cat <<'EOF'
  ___       _ _   _       _     _   _      _                      _        ____       _               
 |_ _|_ __ (_) |_(_) __ _| |   | \ | | ___| |___      _____  _ __| | __   / ___|  ___| |_ _   _ _ __  
  | || '_ \| | __| |/ _` | |   |  \| |/ _ \ __\ \ /\ / / _ \| '__| |/ /   \___ \ / _ \ __| | | | '_ \ 
  | || | | | | |_| | (_| | |   | |\  |  __/ |_ \ V  V / (_) | |  |   <     ___) |  __/ |_| |_| | |_) |
 |___|_| |_|_|\__|_|\__,_|_|___|_| \_|\___|\__| \_/\_/ \___/|_|  |_|\_\___|____/ \___|\__|\__,_| .__/ 
                          |_____|                                    |_____|                   |_|                                                          
EOF
}

hr() { echo "--------------------------------------------------------------------------------"; }

note() { echo -e "\n=== $* ===\n"; }

ask() {
  local prompt="$1"; local default="${2:-}"; local reply
  if [ -n "$default" ]; then
    prompt="$prompt [$default]"
  fi
  read -rp "$prompt: " reply
  if [ -z "$reply" ] && [ -n "$default" ]; then
    reply="$default"
  fi
  echo "$reply"
}

run_cmd() {
  if [[ "${DRYRUN:-no}" == "yes" ]]; then
    echo "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "❌ This script must be run as root (use sudo)."
    exit 1
  fi
}

ensure_dirs() {
  run_cmd "mkdir -p '$BACKUP_DIR' '$MARKER_DIR'"
}

ensure_jq() {
  if command -v jq >/dev/null 2>&1; then return; fi
  if [[ "${DRYRUN:-no}" == "yes" ]]; then
    echo "[DRY-RUN] Would install jq (required for state.json)"
    return
  fi
  apt-get update -y
  apt-get install -y jq
}

state_get() {
  local key="$1"
  if [[ ! -f "$MARKER_FILE" ]]; then echo "unknown"; return; fi
  jq -r --arg k "$key" '.[$k] // "unknown"' "$MARKER_FILE" || echo "unknown"
}

state_set() {
  local key="$1"; local val="$2"
  ensure_jq
  if [[ "${DRYRUN:-no}" == "yes" ]]; then
    echo "[DRY-RUN] state_set $key=$val -> $MARKER_FILE"
    return
  fi
  [[ -f "$MARKER_FILE" ]] || echo "{}" > "$MARKER_FILE"
  local tmp; tmp="$(mktemp)"
  jq --arg k "$key" --arg v "$val" '.[$k]=$v' "$MARKER_FILE" > "$tmp"
  mv "$tmp" "$MARKER_FILE"
}

# --------------------------- Paths & Constants --------------------------------
SCRIPT_NAME="initial_network_setup"
INSTALL_PATH="/usr/local/bin/$SCRIPT_NAME"
BACKUP_DIR="/var/backups/$SCRIPT_NAME"
MARKER_DIR="/var/lib/$SCRIPT_NAME"
MARKER_FILE="$MARKER_DIR/state.json"
SSHD_CONFIG="/etc/ssh/sshd_config"
SYSCTL_CONF="/etc/sysctl.conf"
UFW_USER_RULES="/etc/ufw/user.rules"
UFW_USER6_RULES="/etc/ufw/user6.rules"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"

# --------------------------- Backup / Restore Helpers -------------------------
backup_sshd() {
  if [[ -f "$SSHD_CONFIG" ]]; then
    run_cmd "cp '$SSHD_CONFIG' '$BACKUP_DIR/sshd_config.bak.$TIMESTAMP'"
    state_set "sshd_backup" "$BACKUP_DIR/sshd_config.bak.$TIMESTAMP"
  fi
}

restore_sshd_latest() {
  local latest
  latest="$(ls -t "$BACKUP_DIR"/sshd_config.bak.* 2>/dev/null | head -n1 || true)"
  if [[ -n "$latest" ]]; then
    run_cmd "cp '$latest' '$SSHD_CONFIG'"
    note "Restored sshd_config from $latest"
  else
    note "No sshd_config backup found; skipping."
  fi
}

backup_sysctl() {
  if [[ -f "$SYSCTL_CONF" ]]; then
    run_cmd "cp '$SYSCTL_CONF' '$BACKUP_DIR/sysctl.conf.bak.$TIMESTAMP'"
    state_set "sysctl_backup" "$BACKUP_DIR/sysctl.conf.bak.$TIMESTAMP"
  fi
}

restore_sysctl_latest_or_strip_bbr() {
  local latest
  latest="$(ls -t "$BACKUP_DIR"/sysctl.conf.bak.* 2>/dev/null | head -n1 || true)"
  if [[ -n "$latest" ]]; then
    run_cmd "cp '$latest' '$SYSCTL_CONF'"
    run_cmd "sysctl -p || true"
    note "sysctl.conf restored from $latest"
  else
    run_cmd "sed -i '/^net.core.default_qdisc=fq$/d' '$SYSCTL_CONF' || true"
    run_cmd "sed -i '/^net.ipv4.tcp_congestion_control=bbr$/d' '$SYSCTL_CONF' || true"
    run_cmd "sysctl -p || true"
    note "Removed BBR lines from sysctl.conf (no backup found)."
  fi
}

ufw_is_active() { ufw status 2>/dev/null | grep -qi "active"; }

backup_ufw_state() {
  local installed_before="false"; local was_active="false"
  command -v ufw >/dev/null 2>&1 && installed_before="true"
  [[ "$installed_before" == "true" ]] && ufw_is_active && was_active="true"
  state_set "ufw_installed_before" "$installed_before"
  state_set "ufw_was_active" "$was_active"
  [[ -f "$UFW_USER_RULES" ]] && run_cmd "cp '$UFW_USER_RULES' '$BACKUP_DIR/user.rules.bak.$TIMESTAMP'" && state_set "ufw_user_rules_backup" "$BACKUP_DIR/user.rules.bak.$TIMESTAMP"
  [[ -f "$UFW_USER6_RULES" ]] && run_cmd "cp '$UFW_USER6_RULES' '$BACKUP_DIR/user6.rules.bak.$TIMESTAMP'" && state_set "ufw_user6_rules_backup" "$BACKUP_DIR/user6.rules.bak.$TIMESTAMP"
}

restore_ufw_state_full() {
  local was_active rules_bak rules6_bak
  was_active="$(state_get ufw_was_active)"
  rules_bak="$(state_get ufw_user_rules_backup)"
  rules6_bak="$(state_get ufw_user6_rules_backup)"
  command -v ufw >/dev/null 2>&1 || return
  ufw_is_active && run_cmd "ufw disable"
  [[ -f "$rules_bak" ]] && run_cmd "cp '$rules_bak' '$UFW_USER_RULES'"
  [[ -f "$rules6_bak" ]] && run_cmd "cp '$rules6_bak' '$UFW_USER6_RULES'"
  [[ "$was_active" == "true" ]] && run_cmd "ufw --force enable" && note "UFW restored and enabled." || note "UFW restored and left disabled."
}

# ---------------------------- Self-Install ------------------------------------
offer_self_install() {
  if [[ "$0" != "$INSTALL_PATH" && ! -f "$INSTALL_PATH" ]]; then
    local ans
    ans="$(ask "Install this script to $INSTALL_PATH so it can be run anywhere? (yes/no)" "yes")"
    if [[ "$ans" == "yes" ]]; then
      run_cmd "cp '$0' '$INSTALL_PATH'"
      run_cmd "chmod +x '$INSTALL_PATH'"
      note "Installed to $INSTALL_PATH"
      # Relaunch from installed path
      exec "$INSTALL_PATH" "$@"
    fi
  fi
}

# ==============================================================================
#                                 MAIN
# ==============================================================================
require_root
banner
hr
echo " Script location : $INSTALL_PATH"
echo " Backups stored  : $BACKUP_DIR"
echo " Marker file     : $MARKER_FILE"
hr
echo " 1) Install  — setup SSH port, BBR, Fail2Ban, and (optionally) UFW"
echo " 2) Restore  — FULL RESTORE of original configs and UFW state  [default]"
hr

MODE="$(ask 'Choose mode' '2')"
ensure_dirs
offer_self_install

# ------------------------------- RESTORE MODE ---------------------------------
if [[ "$MODE" == "2" ]]; then
  note "RESTORE mode selected (full restore)."
  DRYRUN="$(ask 'Run in dry-run mode (only print actions, no changes)? (yes/no)' 'no')"
  restore_sshd_latest
  restore_sysctl_latest_or_strip_bbr
  [[ "$(state_get fail2ban_installed_by_script)" == "true" ]] && run_cmd "systemctl stop fail2ban || true; systemctl disable fail2ban || true; apt-get remove -y fail2ban || true" && note "Fail2Ban removed."
  restore_ufw_state_full
  run_cmd "systemctl restart ssh || true"
  state_set "restored_at_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  note "Restore complete."
  exit 0
fi

# ------------------------------- INSTALL MODE ---------------------------------
note "INSTALL mode selected."
DRYRUN="$(ask 'Run in dry-run mode (only print actions, no changes)? (yes/no)' 'no')"

# SSH Port
while true; do
  NEW_SSH_PORT="$(ask 'Enter new SSH port (1025-65534, cannot be 22)' '')"
  [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_SSH_PORT" -gt 1024 ] && [ "$NEW_SSH_PORT" -lt 65535 ] && [ "$NEW_SSH_PORT" -ne 22 ] && break
  echo "Invalid port. Use an integer 1025-65534, not 22."
done
state_set "new_ssh_port" "$NEW_SSH_PORT"

backup_sshd
if grep -qE '^[[:space:]]*Port[[:space:]]+' "$SSHD_CONFIG"; then
  run_cmd "sed -i 's/^[[:space:]]*Port[[:space:]].*/Port $NEW_SSH_PORT/' '$SSHD_CONFIG'"
else
  run_cmd "printf '\\nPort %s\\n' '$NEW_SSH_PORT' >> '$SSHD_CONFIG'"
fi
note "SSH port set to $NEW_SSH_PORT"

# Firewall
DEFAULT_PORTS="443,8443,8080,80,$NEW_SSH_PORT"
PORT_LIST="$(ask "Enter comma-separated allowed ports (default: $DEFAULT_PORTS)" "$DEFAULT_PORTS")"
[[ ",$PORT_LIST," == *",$NEW_SSH_PORT,"* ]] || { echo "❌ Must include SSH port"; exit 1; }
IFS=',' read -r -a PORTS <<< "$PORT_LIST"

# BBR
ENABLE_BBR="$(ask 'Enable BBR congestion control? (yes/no)' 'yes')"
[[ "$ENABLE_BBR" == "yes" ]] && backup_sysctl && { run_cmd "grep -q '^net.core.default_qdisc=fq$' '$SYSCTL_CONF' || echo 'net.core.default_qdisc=fq' >> '$SYSCTL_CONF'"; run_cmd "grep -q '^net.ipv4.tcp_congestion_control=bbr$' '$SYSCTL_CONF' || echo 'net.ipv4.tcp_congestion_control=bbr' >> '$SYSCTL_CONF'"; run_cmd "sysctl -p"; state_set "bbr_enabled_by_script" "true"; note "BBR enabled.";} || state_set "bbr_enabled_by_script" "false"

# Fail2Ban
INSTALL_F2B="$(ask 'Install and enable Fail2Ban? (yes/no)' 'yes')"
if [[ "$INSTALL_F2B" == "yes" ]]; then
  run_cmd "apt-get update -y"
  run_cmd "apt-get install -y fail2ban"
  run_cmd "systemctl enable fail2ban"
  run_cmd "systemctl start fail2ban"
  state_set "fail2ban_installed_by_script" "true"
  note "Fail2Ban installed."
else
  state_set "fail2ban_installed_by_script" "false"
fi

# Restart SSH
RESTART_SSH="$(ask 'Restart SSH server now? (yes/no)' 'yes')"
[[ "$RESTART_SSH" == "yes" ]] && run_cmd "systemctl restart ssh" || note "Remember to restart SSH later."

# UFW
ENABLE_UFW="$(ask 'Activate UFW now? (yes/no) — default NO' 'no')"
if [[ "$ENABLE_UFW" != "yes" ]]; then
  note "UFW not enabled. You can enable it later safely after updating allowed ports."
else
  for p in "${PORTS[@]}"; do
    run_cmd "ufw allow $p/tcp" || true
    run_cmd "ufw allow $p/udp" || true
  done
  run_cmd "ufw --force enable"
  note "UFW enabled and ports allowed."
fi

note "INSTALL complete. Remember to update settings if needed."
state_set "installed_at_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
